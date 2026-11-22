"""karabiner.json の検査。python3 tests/test_karabiner.py で回す (tests/run.sh からも呼ぶ)。

1. 動作の確認: 過去に壊れた / 壊れやすい操作を、シミュレーターで押して出力を確かめる
2. 静的な検査: Karabiner 付属の lint、絶対に当たらない設定、レイヤーの受け皿の抜け、トンネルの数字
3. ファイル間の整合: Karabiner が送るキーと、Hammerspoon / DownloadsShelf / AHK / Chrome 拡張が受けるキー
4. ファズ: 押す/離す・アプリ切替・入力切替を乱数で流し、全部離して待った後に変数が残らないか

ファズの回数と乱数の種は FUZZ_N / FUZZ_SEED で変えられる (既定 1 万回、種 1)。
"""

import itertools
import json
import os
import random
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True  # tests/__pycache__ を作らない

import karabiner_sim as ks  # noqa: E402

# KARABINER_JSON で別のファイル (配布先の ~/.config/karabiner/karabiner.json など) を検査できる
KARABINER_JSON = os.environ.get("KARABINER_JSON") or os.path.join(ROOT, "karabiner", "karabiner.json")
INIT_LUA = os.path.join(ROOT, "hammerspoon", "init.lua")
SHELF_SWIFT = os.path.join(ROOT, "downloads-shelf", "DownloadsShelf.swift")
AHK = os.path.join(ROOT, "karabiner", "assets", "ahk", "parallels_window_move.ahk")
CHROME_EXT = os.path.join(ROOT, "chrome-extension")
KARABINER_CLI = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"

CFG = ks.Config(KARABINER_JSON)


def read(path):
    with open(path, encoding="utf-8") as fp:
        return fp.read()


def press(sim, *keys, gap=40):
    """keys を順に押して、逆順に離す (同時押し)。"""
    for k in keys:
        sim.down(k, sim.now + gap)
    for k in reversed(keys):
        sim.up(k, sim.now + gap)


def run(app=ks.FINDER, inp=ks.JAPANESE, steps=()):
    sim = ks.Simulator(CFG, app, inp)
    for s in steps:
        s(sim)
    sim.release_all()
    return sim.taps()


# 物理キーの名前 (simple_modifications の前)
EISUU = "japanese_eisuu"   # → F13 (F13 レイヤー)
TAB = "tab"                # → 英数 (英数レイヤー)
KANA = "japanese_kana"     # → F21 (スペース右)
PCTRL = "left_control"     # → left_command (物理 Ctrl が Cmd)
RO = "international1"      # ろ / _


class Behaviour(unittest.TestCase):
    """過去に壊れた / 壊れやすい操作の出力。"""

    def test_f13_layer_arrows(self):
        self.assertEqual(run(steps=[lambda s: press(s, EISUU, "j")]), ["down_arrow"])

    def test_eisuu_layer_escape(self):
        self.assertEqual(run(steps=[lambda s: press(s, TAB, "q")]), ["japanese_eisuu", "escape"])

    def test_tunnel_in_parallels(self):
        self.assertEqual(run(ks.PARALLELS_WINAPP, steps=[lambda s: press(s, EISUU, "q")]), ["⌃⌥⌘h"])
        self.assertEqual(run(ks.PARALLELS_CONSOLE, steps=[lambda s: press(s, TAB)]), ["⌃f19"])

    def test_f13_v_only_in_chrome(self):
        self.assertEqual(run(ks.CHROME, steps=[lambda s: press(s, EISUU, "v")]), ["⌥⇧v"])
        for app in [ks.FINDER, ks.PARALLELS_WINAPP]:
            self.assertEqual(run(app, steps=[lambda s: press(s, EISUU, "v")]), ["vk_none"], app)

    def test_ro_key(self):
        self.assertEqual(run(steps=[lambda s: press(s, RO)]), ["international1"])
        self.assertEqual(run(ks.PARALLELS_WINAPP, steps=[lambda s: press(s, RO)]), ["⇧international1"])
        self.assertEqual(run(steps=[lambda s: press(s, "left_shift", RO)]), ["⌥international3"])
        self.assertEqual(run(ks.PARALLELS_WINAPP, steps=[lambda s: press(s, "left_shift", RO)]),
                         ["international3"])

    def test_cmd_i_katakana(self):
        self.assertEqual(run(steps=[lambda s: press(s, PCTRL, "i")]), ["f7"])
        self.assertEqual(run(inp=ks.ROMAN, steps=[lambda s: press(s, PCTRL, "i")]), ["⌘i"])
        self.assertEqual(run(steps=[lambda s: press(s, "left_option", PCTRL, "i")]), ["⌥⌘i"])
        self.assertEqual(run(ks.PARALLELS_WINAPP, steps=[lambda s: press(s, PCTRL, "i")]), ["⌃i"])

    def test_space_right_backspace(self):
        one = run(steps=[lambda s: s.tap(KANA, s.now + 50)])
        self.assertEqual(one, [], "1回目は何も出さない")
        three = run(steps=[lambda s: [s.tap(KANA, s.now + 150) for _ in range(3)]])
        self.assertEqual(three, ["delete_or_backspace"] * 2)
        slow = run(steps=[lambda s: [s.tap(KANA, s.now + 600) for _ in range(2)]])
        self.assertEqual(slow, [], "間が空いたら2回目も1回目扱い")
        jkl = run(steps=[lambda s: press(s, KANA, "j", "k")])
        self.assertEqual(jkl, ["delete_or_backspace", "vk_none", "delete_or_backspace", "vk_none"])
        self.assertEqual(run(steps=[lambda s: press(s, EISUU, KANA)]), ["delete_forward"])

    def test_f13_c_double(self):
        self.assertEqual(run(steps=[lambda s: press(s, EISUU, "c")]), ["f19"])

        def twice(s):
            s.down(EISUU, s.now + 10)
            s.tap("c", s.now + 50)
            s.tap("c", s.now + 200)
            s.up(EISUU, s.now + 50)
        self.assertEqual(run(steps=[twice]), ["f19", "⌃⌥⌘f19"])

    def test_left_cmd_double_tap(self):
        for app in [ks.FINDER, ks.PARALLELS_WINAPP]:
            taps = run(app, steps=[lambda s: [s.tap(PCTRL, s.now + 80) for _ in range(2)]])
            self.assertEqual(taps, ["⇧⌘v"], app)

    def test_cmd_c_double(self):
        def twice(s):
            s.down(PCTRL, s.now + 10)
            s.tap("c", s.now + 50)
            s.tap("c", s.now + 200)
            s.up(PCTRL, s.now + 50)
        self.assertEqual(run(steps=[twice]), ["⌘c", "⌘right_arrow", "⇧⌘left_arrow", "⌘c"])
        self.assertEqual(run(ks.PARALLELS_WINAPP, steps=[twice]), ["⌃c", "end", "⇧home", "⌃c"])

    def test_drawio_physical_ctrl(self):
        self.assertEqual(run(ks.DRAWIO, steps=[lambda s: press(s, PCTRL, "c")]), ["⌃c"])


def condition_values(manips):
    """条件に出てくる変数ごとに、試すべき値 (0 と条件の値) を集める。"""
    vals = {}
    for m in manips:
        for c in m.conditions:
            if c["type"].startswith("variable_"):
                vals.setdefault(c["name"], {0}).add(c["value"])
    return {k: sorted(v) for k, v in vals.items()}


STATIC_MODS = ["left_command", "left_control", "left_option", "left_shift", "right_shift", "caps_lock"]


class Static(unittest.TestCase):

    def test_karabiner_lint(self):
        if not os.path.exists(KARABINER_CLI):
            self.skipTest("karabiner_cli が無い")
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as fp:
            json.dump({"title": "lint", "rules": CFG.rules}, fp, ensure_ascii=False)
        try:
            r = subprocess.run([KARABINER_CLI, "--lint-complex-modifications", fp.name],
                               capture_output=True, text=True)
        finally:
            os.unlink(fp.name)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_no_unreachable_manipulator(self):
        """前の設定に完全に隠されて、どの状態でも当たらない設定が無いこと。"""
        dead = []
        for key in sorted({m.from_key for m in CFG.manipulators}):
            manips = CFG.by_key(key)
            vals = condition_values(manips)
            names = list(vals)
            reached = set()
            for combo in itertools.product(*(vals[n] for n in names)):
                variables = dict(zip(names, combo))
                for app in ks.APPS:
                    for inp in ks.INPUTS:
                        env = ks.Env(app, inp, variables)
                        for r in range(len(STATIC_MODS) + 1):
                            for mods in itertools.combinations(STATIC_MODS, r):
                                m, _ = ks.first_match(manips, key, set(mods), env)
                                if m:
                                    reached.add(id(m))
            dead += [m.label() for m in manips if id(m) not in reached]
        self.assertEqual(dead, [], "どの状態でも当たらない設定")

    def test_layer_has_fallback(self):
        """レイヤーで使うキーは、どのアプリ・入力でも何かの設定に当たる (素のキーが漏れない)。"""
        leaks = []
        for var in ["f13_pressed", "tab_held"]:
            # マウスボタン (F13+クリック) は Chrome 以外で素のクリックになるのが正しいので除く
            keys = {m.from_key for m in CFG.manipulators
                    if {"type": "variable_if", "name": var, "value": 1} in m.conditions
                    and not m.raw["from"].get("pointing_button")}
            for key in sorted(keys):
                for app in ks.APPS:
                    for inp in ks.INPUTS:
                        m, _ = ks.first_match(CFG.manipulators, key, set(), ks.Env(app, inp, {var: 1}))
                        if m is None:
                            leaks.append(f"{var}: {key} が {app} / {inp['input_mode_id']} で素通り")
        self.assertEqual(leaks, [])

    def test_tunnel_has_no_digits(self):
        """⌃⌘ を含む出力に数字を使わない (Finder が ⌃⌘0 / ⌃⌥⌘0〜8 を持っているため)。"""
        bad = [f"{m.label()}: {k} {sorted(mods)}" for m in CFG.manipulators for k, mods in m.outputs()
               if re.fullmatch(r"[0-9]", k)
               and ks.expand(mods) & ks.GENERIC["control"] and ks.expand(mods) & ks.GENERIC["command"]]
        self.assertEqual(bad, [])


# --- ファイル間の整合 ---

NORM = {"left_control": "ctrl", "right_control": "ctrl", "control": "ctrl",
        "left_option": "alt", "right_option": "alt", "option": "alt",
        "left_command": "cmd", "right_command": "cmd", "command": "cmd",
        "left_shift": "shift", "right_shift": "shift", "shift": "shift"}


def norm(key, mods):
    return key.lower(), frozenset(NORM[m] for m in mods)


def is_tunnel(key, mods):
    """Karabiner から他のプログラムへ合図として送るキーか。"""
    m = {NORM.get(x, x) for x in mods}
    if re.fullmatch(r"f1[5-9]|f20", key):
        return True
    if {"ctrl", "alt", "cmd"} <= m:
        return True
    return m == {"ctrl"} and re.fullmatch(r"f1[3-9]|f2[0-4]", key) is not None


def karabiner_tunnels():
    out = {}
    for m in CFG.manipulators:
        for k, mods in m.outputs():
            if is_tunnel(k, mods):
                out.setdefault(norm(k, mods), []).append(m.label())
    return out


def hs_receivers():
    src = read(INIT_LUA)
    named = {}
    for name, body in re.findall(r"local (\w+)\s*=\s*\{([^{}]*)\}", src):
        named[name] = re.findall(r'"(\w+)"', body)
    block = re.search(r"local TRIGGERS = \{(.*?)\n\}", src, re.S).group(1)
    recv = {}
    for line in block.splitlines():
        km = re.search(r'key\s*=\s*"(\w+)"', line)
        if not km:
            continue
        mm = re.search(r"mods\s*=\s*(\w+)", line)
        mods = named[mm.group(1)] if mm else []
        recv[norm(km.group(1), [{"ctrl": "control", "alt": "option", "cmd": "command"}.get(x, x)
                                for x in mods])] = "hammerspoon/init.lua TRIGGERS"
    return recv


def shelf_receivers():
    src = read(SHELF_SWIFT)
    recv = {}
    for key, mods in re.findall(r"RegisterEventHotKey\(UInt32\(kVK_(\w+)\),\s*UInt32\(([^)]*)\)", src):
        names = {"controlKey": "control", "optionKey": "option", "cmdKey": "command", "shiftKey": "shift"}
        recv[norm(key, [names[x.strip()] for x in mods.split("|")])] = "DownloadsShelf.swift"
    return recv


def ahk_receivers():
    recv = {}
    names = {"^": "control", "!": "option", "#": "command", "+": "shift"}
    for line in read(AHK).splitlines():
        hm = re.match(r"\s*([\^!#+]+)(\w+)::", line)
        if hm:
            recv[norm(hm.group(2), [names[c] for c in hm.group(1)])] = "parallels_window_move.ahk"
    return recv


def chrome_shortcuts():
    out = {}
    for ext in sorted(os.listdir(CHROME_EXT)):
        path = os.path.join(CHROME_EXT, ext, "manifest.json")
        if not os.path.exists(path):
            continue
        manifest = json.loads(read(path))
        for cmd, spec in manifest.get("commands", {}).items():
            key = spec.get("suggested_key", {}).get("mac") or spec.get("suggested_key", {}).get("default")
            if key:
                *mods, k = key.split("+")
                m = {"Alt": "option", "Shift": "shift", "Ctrl": "control", "Command": "command",
                     "MacCtrl": "control"}
                out[norm(k, [m[x] for x in mods])] = f"{ext}/{cmd}"
    return out


class CrossFile(unittest.TestCase):

    def test_every_tunnel_has_receiver(self):
        recv = {**hs_receivers(), **shelf_receivers(), **ahk_receivers()}
        sent = karabiner_tunnels()
        missing = [f"{k} {sorted(m)} ← {labels[0]}" for (k, m), labels in sent.items() if (k, m) not in recv]
        self.assertEqual(missing, [], "Karabiner が送るのに誰も受けないキー")

    def test_every_receiver_has_sender(self):
        recv = {**hs_receivers(), **shelf_receivers(), **ahk_receivers()}
        sent = karabiner_tunnels()
        orphan = [f"{k} {sorted(m)} ({where})" for (k, m), where in recv.items() if (k, m) not in sent]
        self.assertEqual(orphan, [], "受け手だけあって Karabiner が送らないキー")

    def test_chrome_shortcuts_are_sent_in_chrome(self):
        sent = set()
        for m in CFG.manipulators:
            if any(c["type"] == "frontmost_application_if" and
                   any(re.search(p, ks.CHROME) for p in c["bundle_identifiers"]) for c in m.conditions):
                sent |= {norm(k, mods) for k, mods in m.outputs()}
        missing = [f"{k} {sorted(m)} ({ext})" for (k, m), ext in chrome_shortcuts().items()
                   if (k, m) not in sent]
        self.assertEqual(missing, [], "拡張のショートカットを Chrome 前面で送る設定が無い")


# --- ファズ ---

FUZZ_KEYS = [EISUU, TAB, KANA, PCTRL, "left_command", "left_option", "left_shift", "right_shift",
             "right_command", "h", "j", "k", "l", "c", "v", "g", "q", "e", "i", "1", "3",
             RO, "international3", "spacebar", "button1", "button2"]
GAPS = [5, 30, 80, 150, 240, 260, 290, 320, 390, 420, 480, 520, 900, 1100]


def random_actions(rnd):
    actions, held = [], set()
    for _ in range(rnd.randint(1, 30)):
        r = rnd.random()
        gap = rnd.choice(GAPS)
        if r < 0.08:
            actions.append(("app", rnd.choice(ks.APPS), gap))
        elif r < 0.12:
            actions.append(("input", rnd.choice(ks.INPUTS)["input_mode_id"], gap))
        elif held and r < 0.5:
            k = rnd.choice(sorted(held))
            held.discard(k)
            actions.append(("up", k, gap))
        else:
            k = rnd.choice(FUZZ_KEYS)
            held.add(k)
            actions.append(("down", k, gap))
    return actions


def replay(actions):
    sim = ks.Simulator(CFG, ks.FINDER, ks.JAPANESE)
    inputs = {i["input_mode_id"]: i for i in ks.INPUTS}
    for kind, arg, gap in actions:
        t = sim.now + gap
        if kind == "app":
            sim.advance(t)
            sim.env.app = arg
        elif kind == "input":
            sim.advance(t)
            sim.env.input = inputs[arg]
        elif kind == "down":
            sim.down(arg, t)
        else:
            sim.up(arg, t)
    sim.release_all()
    sim.idle(5000)
    return {k: v for k, v in sim.env.vars.items() if v != 0}


def shrink(actions):
    """失敗が再現する範囲で、操作を1つずつ削って短くする。"""
    changed = True
    while changed:
        changed = False
        for i in range(len(actions)):
            cand = actions[:i] + actions[i + 1:]
            if replay(cand):
                actions, changed = cand, True
                break
    return actions


class Fuzz(unittest.TestCase):

    def test_no_variable_left_after_idle(self):
        n = int(os.environ.get("FUZZ_N", "10000"))
        seed = int(os.environ.get("FUZZ_SEED", "1"))
        rnd = random.Random(seed)
        for i in range(n):
            actions = random_actions(rnd)
            left = replay(actions)
            if left:
                small = shrink(actions)
                lines = "\n".join(f"  +{g}ms {k} {a}" for k, a, g in small)
                self.fail(f"全部離して 5 秒待っても変数が残った: {replay(small)}\n"
                          f"(FUZZ_SEED={seed} の {i} 回目。縮めた操作列)\n{lines}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
