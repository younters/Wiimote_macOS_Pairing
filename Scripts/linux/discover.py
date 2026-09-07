#!/usr/bin/env python3
"""Discover Wii candidates using a real LIAC inquiry; write an atomic local JSON result.
Run as root on Linux with the USB Bluetooth adapter. Does not pair any device.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import time


def parse_event(packet):
    if len(packet) < 4 or packet[0] != 4:
        return []
    event, length = packet[1:3]
    data = packet[3:]
    if len(data) != length or event not in (0x02, 0x22, 0x2F):
        return []
    count = data[0]
    stride = 254 if event == 0x2F else 14
    if len(data) != 1 + count * stride:
        return []
    results = []
    for i in range(count):
        item = data[1 + i * stride:1 + (i + 1) * stride]
        address = ':'.join(f'{b:02X}' for b in item[:6][::-1])
        offset = 9 if event == 0x02 else 8
        cod = int.from_bytes(item[offset:offset + 3], 'little')
        results.append({'address': address, 'class_of_device': cod})
    return results


def discover(adapter):
    found = {}
    accepted = False
    with socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI) as radio:
        radio.bind((adapter,))
        radio.setsockopt(socket.SOL_HCI, socket.HCI_FILTER, struct.pack('=IIIHxx', 1 << 4, 0xFFFFFFFF, 0xFFFFFFFF, 0))
        radio.settimeout(1)
        radio.send(bytes.fromhex('01 01 04 05 00 8b 9e 08 00'))
        deadline = time.monotonic() + 15
        try:
            while time.monotonic() < deadline:
                try:
                    packet = radio.recv(4096)
                except socket.timeout:
                    continue
                if len(packet) >= 7 and packet[0:2] == b'\x04\x0f' and packet[5:7] == b'\x01\x04':
                    if packet[3] != 0:
                        raise RuntimeError(f'LIAC rejected: HCI status 0x{packet[3]:02x}')
                    accepted = True
                if accepted:
                    for record in parse_event(packet):
                        found[record['address']] = record
                    if packet[:2] == b'\x04\x01':
                        if len(packet) != 4 or packet[3] != 0:
                            raise RuntimeError(f'Inquiry completion error: {packet.hex()}')
                        accepted = False
                        return list(found.values())
            raise TimeoutError('No successful LIAC inquiry completion within 15 seconds')
        finally:
            if accepted:
                radio.send(bytes.fromhex('01 02 04 00'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adapter', type=int, default=0)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = {'schema': 1, 'source': 'linux-liac', 'devices': []}
    try:
        records = discover(args.adapter)
        for record in records:
            # Resolve peripheral names only, after inquiry has finished.
            if record['class_of_device'] & 0x1F00 == 0x0500:
                try:
                    response = subprocess.run(['hcitool', '-i', f'hci{args.adapter}', 'name', record['address']],
                                              capture_output=True, text=True, timeout=12)
                    record['name'] = response.stdout.strip() if response.returncode == 0 else ''
                except (OSError, subprocess.TimeoutExpired):
                    record['name'] = ''
            result['devices'].append(record)
        result['status'] = 'complete'
    except Exception as error:
        result['status'] = 'error'
        result['error'] = str(error)
    result['observed_at'] = time.time()
    result['observed_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temp = args.output.with_suffix('.tmp')
    temp.write_text(json.dumps(result, indent=2) + '\n')
    os.replace(temp, args.output)
    print(json.dumps(result), flush=True)
    return 0 if result['status'] == 'complete' else 1


if __name__ == '__main__':
    raise SystemExit(main())
