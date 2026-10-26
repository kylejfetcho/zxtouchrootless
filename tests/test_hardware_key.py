import os
import sys
import unittest


PYTHON_CLIENT_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "layout", "usr", "share", "zxtouch", "python")
)
sys.path.insert(0, PYTHON_CLIENT_ROOT)
sys.path.insert(0, os.path.dirname(__file__))

from zxtouch import tasktypes  # noqa: E402
from test_screenshot import make_device  # noqa: E402


class HardwareKeyProtocolTests(unittest.TestCase):
    def test_home_press_wire_format(self):
        device = make_device([b"0\r\n"])

        self.assertEqual(device.hardware_key(0x0C, 0x40), (True, []))
        self.assertEqual(device.s.sent, [b"3112;;64;;press\r\n"])

    def test_task_id(self):
        self.assertEqual(tasktypes.TASK_HARDWARE_KEY, 31)

    def test_error_reply(self):
        device = make_device([b"-1;;Unknown action. action should be press, down or up.\r\n"])

        ok, message = device.hardware_key(0x0C, 0x30, "hold")
        self.assertFalse(ok)
        self.assertEqual(message, "Unknown action. action should be press, down or up.")
        self.assertEqual(device.s.sent, [b"3112;;48;;hold\r\n"])


if __name__ == "__main__":
    unittest.main()
