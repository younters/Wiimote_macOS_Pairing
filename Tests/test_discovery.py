import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('discovery', Path(__file__).parents[1] / 'Scripts/linux/discover.py')
discovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(discovery)


class InquiryPackets(unittest.TestCase):
    def test_standard_and_rssi_addresses_and_classes(self):
        # Wire addresses are little-endian. CoD starts at a different offset with RSSI.
        for event, body in [(2, bytes.fromhex('bc 9a 78 56 34 12 01 00 00 04 25 00 00 00')),
                            (0x22, bytes.fromhex('bc 9a 78 56 34 12 01 00 04 25 00 00 00 d0'))]:
            packet = bytes([4, event, 15, 1]) + body
            self.assertEqual(discovery.parse_event(packet), [{'address': '12:34:56:78:9A:BC', 'class_of_device': 0x2504}])
            self.assertEqual(discovery.parse_event(packet[:-1]), [])

    def test_extended_result(self):
        body = bytes.fromhex('bc 9a 78 56 34 12 01 00 04 25 00 00 00 d0') + bytes(240)
        result = discovery.parse_event(bytes([4, 0x2f, 255, 1]) + body)
        self.assertEqual(result[0]['class_of_device'], 0x2504)

    def test_control_events_are_not_devices(self):
        for packet in [b'', bytes.fromhex('04 0f 04 00 01 01 04'), bytes.fromhex('04 01 01 00')]:
            self.assertEqual(discovery.parse_event(packet), [])


if __name__ == '__main__':
    unittest.main()
