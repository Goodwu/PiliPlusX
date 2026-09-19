import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
LAYOUT = ROOT / "tool/ohos/ohos_ui_layout.py"
MARKERS = ROOT / "tool/ohos/verify_player_button_markers.py"


def layout(button_opacity="1", slider=True):
    children = []
    if slider:
        children.append({"attributes": {"type": "Slider", "visible": "true", "bounds": "[10,900][990,930]"}})
    children.append({"attributes": {
        "type": "Button", "id": "pl-player-fullscreen-toggle", "text": "全屏",
        "clickable": "true", "visible": "true", "opacity": button_opacity,
        "bounds": "[900,880][980,960]",
    }})
    return {"attributes": {"bundleName": "com.example.piliplusx"}, "children": children}


class OhosPlayerButtonVerifierTest(unittest.TestCase):
    def run_layout(self, mode, payload):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "layout.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(LAYOUT), mode, str(path)],
                text=True, capture_output=True,
            )

    def run_markers(self, text, **overrides):
        args = {
            "offset": 0, "expected": "enter", "pid": "7545", "view_id": "0",
            "epoch": "1", "consumed_before": 0,
        }
        args.update(overrides)
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "hilog.txt"
            path.write_text(text, encoding="utf-8")
            command = [sys.executable, str(MARKERS), "--hilog", str(path)]
            for key, value in args.items():
                command += ["--" + key.replace("_", "-"), str(value)]
            return subprocess.run(command, text=True, capture_output=True)

    def test_painted_target_rejects_opacity_zero_but_fresh_diagnoses_it(self):
        hidden = layout("0.000000")
        self.assertNotEqual(self.run_layout("fullscreen-button", hidden).returncode, 0)
        self.assertEqual(self.run_layout("fullscreen-button-fresh", hidden).returncode, 0)

    def test_fresh_target_rejects_stale_opacity_zero_without_control_band(self):
        self.assertNotEqual(
            self.run_layout("fullscreen-button-fresh", layout("0", slider=False)).returncode,
            0,
        )

    def test_marker_proof_requires_exact_pid_view_epoch_and_order(self):
        proof = "\n".join([
            "09:52:59 7545 hcpp_input stage=owner route=input seq=83 epoch=1 TouchType=Down",
            "09:52:59 7545 hcpp_input stage=owner route=input seq=84 epoch=1 TouchType=Up",
            "09:52:59 7545 PlayerTouchTrace fullscreen-button pointer-down viewId=0",
            "09:52:59 7545 PlayerTouchTrace fullscreen-button pointer-up viewId=0",
            "09:52:59 7545 PlayerTouchTrace fullscreen-button callback target=true",
            "09:52:59 7545 FullscreenTrace trigger status=true",
        ])
        self.assertEqual(self.run_markers(proof).returncode, 0)
        self.assertNotEqual(self.run_markers(proof, pid="9999").returncode, 0)
        self.assertNotEqual(self.run_markers(proof, view_id="7").returncode, 0)
        self.assertNotEqual(self.run_markers(proof, epoch="2").returncode, 0)
        unordered = "\n".join([
            "09:52:59 7545 hcpp_input stage=owner route=input seq=83 epoch=1 TouchType=Down",
            "09:52:59 7545 hcpp_input stage=owner route=input seq=84 epoch=1 TouchType=Up",
            "09:52:59 7545 PlayerTouchTrace fullscreen-button pointer-down viewId=0",
            "09:52:59 7545 PlayerTouchTrace fullscreen-button callback target=true",
            "09:52:59 7545 PlayerTouchTrace fullscreen-button pointer-up viewId=0",
            "09:52:59 7545 FullscreenTrace trigger status=true",
        ])
        self.assertNotEqual(self.run_markers(unordered).returncode, 0)

    def test_old_or_consumed_marker_set_cannot_prove_a_new_action(self):
        proof = "\n".join([
            "09:52:59 7545 hcpp_input stage=owner route=input seq=83 epoch=1 TouchType=Down",
            "09:52:59 7545 hcpp_input stage=owner route=input seq=84 epoch=1 TouchType=Up",
            "09:52:59 7545 PlayerTouchTrace fullscreen-button pointer-down viewId=0",
            "09:52:59 7545 PlayerTouchTrace fullscreen-button pointer-up viewId=0",
            "09:52:59 7545 PlayerTouchTrace fullscreen-button callback target=true",
            "09:52:59 7545 FullscreenTrace trigger status=true\n",
        ])
        self.assertNotEqual(self.run_markers(proof, offset=len(proof.encode())).returncode, 0)
        self.assertNotEqual(
            self.run_markers(proof, consumed_before=len(proof.encode())).returncode,
            0,
        )

    def test_flutter_texture_channel_proves_ordered_markers_without_hcpp(self):
        proof = "\n".join([
            "09:52:59 7545 PlayerTouchTrace fullscreen-button pointer-down viewId=0",
            "09:52:59 7545 PlayerTouchTrace fullscreen-button pointer-up viewId=0",
            "09:52:59 7545 PlayerTouchTrace fullscreen-button callback target=true",
            "09:52:59 7545 FullscreenTrace trigger status=true",
        ])
        result = self.run_markers(proof, input_channel="flutter", epoch="0")
        self.assertEqual(result.returncode, 0)
        self.assertRegex(result.stdout, r"^none\tnone\t\d+\n$")
        self.assertNotEqual(self.run_markers(proof, epoch="0").returncode, 0)


if __name__ == "__main__":
    unittest.main()
