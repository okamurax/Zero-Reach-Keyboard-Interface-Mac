"""karabiner.json を読んで、Karabiner-Elements の判定を真似る小さなシミュレーター。

真似るのは、このリポジトリの karabiner.json が実際に使っている機能だけ:
  - 物理キーの置き換え (devices[is_keyboard].simple_modifications)。complex より先に効く
  - complex の basic マニピュレーター。上から順に見て、最初に当たった1つだけが効く
  - from: key_code / pointing_button、modifiers の mandatory / optional
  - conditions: variable_if/unless, frontmost_application_if/unless, input_source_if
  - to / to_if_alone / to_after_key_up / to_delayed_action と、その時間の parameters
知らない機能が出てきたら黙って無視せず UnsupportedFeature を投げる (真似の漏れに気づくため)。

前提 (ドキュメントに書かれておらず、実機の動きから決めたもの):
  - to_delayed_action の待ちは from の key_down から数える。
  - 待ちを取り消すのは、その後の key_down (同じキーの2回目も含む) とマウスボタン。
  - 取り消し (to_if_canceled) は、その key_down に当たったマニピュレーターの to を実行した「後」に走る。
    こうしないと、スペース右の3回目の BS と左 Cmd の2回叩きが実機どおりに出ない。
"""

import json
import re

PARALLELS_CONSOLE = "com.parallels.desktop.console"
PARALLELS_WINAPP = "com.parallels.winapp.example.notepad"  # Coherence の Windows アプリ (ID の後半は VM ごとに違う)
CHROME = "com.google.Chrome"
DRAWIO = "com.jgraph.drawio.desktop"
FINDER = "com.apple.finder"
APPS = [FINDER, CHROME, DRAWIO, PARALLELS_CONSOLE, PARALLELS_WINAPP]

JAPANESE = {"input_mode_id": "com.apple.inputmethod.Japanese.Hiragana", "language": "ja"}
ROMAN = {"input_mode_id": "com.apple.inputmethod.Roman", "language": "en"}
INPUTS = [JAPANESE, ROMAN]

MODIFIER_KEYS = {
    "left_command", "right_command", "left_control", "right_control",
    "left_option", "right_option", "left_shift", "right_shift", "caps_lock", "fn",
}
GENERIC = {
    "command": {"left_command", "right_command"},
    "control": {"left_control", "right_control"},
    "option": {"left_option", "right_option"},
    "shift": {"left_shift", "right_shift"},
}

KNOWN_MANIP_KEYS = {
    "type", "description", "from", "to", "conditions", "parameters",
    "to_if_alone", "to_after_key_up", "to_delayed_action",
}
KNOWN_TO_KEYS = {"key_code", "pointing_button", "modifiers", "set_variable", "lazy", "repeat"}
KNOWN_PARAMS = {
    "basic.to_delayed_action_delay_milliseconds",
    "basic.to_if_alone_timeout_milliseconds",
}


class UnsupportedFeature(Exception):
    pass


def expand(mods):
    out = set()
    for m in mods:
        out |= GENERIC.get(m, {m})
    return out


class Manipulator:
    def __init__(self, raw, rule_index, rule_desc, index):
        unknown = set(raw) - KNOWN_MANIP_KEYS
        if unknown or raw.get("type") != "basic":
            raise UnsupportedFeature(f"manipulator keys {unknown} / type {raw.get('type')}")
        self.raw = raw
        self.rule_index = rule_index
        self.rule_desc = rule_desc
        self.index = index
        self.desc = raw.get("description") or rule_desc
        f = raw["from"]
        if set(f) - {"key_code", "pointing_button", "modifiers"}:
            raise UnsupportedFeature(f"from keys {set(f)}")
        self.from_key = f.get("key_code") or f.get("pointing_button")
        mods = f.get("modifiers", {})
        self.mandatory = mods.get("mandatory", [])
        self.optional = mods.get("optional", [])
        self.conditions = raw.get("conditions", [])
        params = raw.get("parameters", {})
        if set(params) - KNOWN_PARAMS:
            raise UnsupportedFeature(f"parameters {set(params)}")
        self.delay_ms = params.get("basic.to_delayed_action_delay_milliseconds", 500)
        self.alone_ms = params.get("basic.to_if_alone_timeout_milliseconds", 1000)
        self.to = raw.get("to", [])
        self.to_if_alone = raw.get("to_if_alone", [])
        self.to_after_key_up = raw.get("to_after_key_up", [])
        self.delayed = raw.get("to_delayed_action")
        for seq in [self.to, self.to_if_alone, self.to_after_key_up,
                    *(self.delayed or {}).values()]:
            for t in seq:
                if set(t) - KNOWN_TO_KEYS:
                    raise UnsupportedFeature(f"to keys {set(t)}")

    def label(self):
        return f"rule {self.rule_index} / #{self.index}: {self.desc[:60]}"

    def outputs(self):
        """(key, 修飾キーの集合) を、このマニピュレーターが送り得るものすべてについて返す。"""
        seqs = [self.to, self.to_if_alone, self.to_after_key_up, *(self.delayed or {}).values()]
        for seq in seqs:
            for t in seq:
                k = t.get("key_code") or t.get("pointing_button")
                if k:
                    yield k, frozenset(t.get("modifiers", []))


class Config:
    def __init__(self, path):
        with open(path, encoding="utf-8") as fp:
            data = json.load(fp)
        profile = next(p for p in data["profiles"] if p.get("selected"))
        self.simple = {}
        for m in profile.get("simple_modifications", []):
            self.simple[m["from"]["key_code"]] = m["to"][0]["key_code"]
        for dev in profile.get("devices", []):
            if dev.get("identifiers", {}).get("is_keyboard") and len(dev["identifiers"]) == 1:
                for m in dev.get("simple_modifications", []):
                    self.simple[m["from"]["key_code"]] = m["to"][0]["key_code"]
        self.rules = profile["complex_modifications"]["rules"]
        self.manipulators = []
        for ri, rule in enumerate(self.rules):
            for mi, raw in enumerate(rule["manipulators"]):
                self.manipulators.append(Manipulator(raw, ri, rule.get("description", ""), mi))

    def by_key(self, key):
        return [m for m in self.manipulators if m.from_key == key]


def modifiers_match(m, held):
    """from.modifiers の判定。当たれば mandatory で使った修飾キーの集合を、外れなら None を返す。"""
    used = set()
    for mm in m.mandatory:
        hit = held & GENERIC.get(mm, {mm})
        if not hit:
            return None
        used |= hit
    rest = held - used
    if "any" in m.optional:
        return used
    if rest - expand(m.optional):
        return None
    return used


def condition_match(c, env):
    t = c["type"]
    if t in ("variable_if", "variable_unless"):
        hit = env.vars.get(c["name"], 0) == c["value"]
    elif t in ("frontmost_application_if", "frontmost_application_unless"):
        if set(c) - {"type", "bundle_identifiers", "description"}:
            raise UnsupportedFeature(f"condition {c}")
        hit = any(re.search(p, env.app) for p in c["bundle_identifiers"])
    elif t == "input_source_if":
        hit = any(all(re.search(v, env.input.get(k, "")) for k, v in src.items())
                  for src in c["input_sources"])
    else:
        raise UnsupportedFeature(f"condition type {t}")
    return hit if t.endswith("_if") else not hit


class Env:
    def __init__(self, app=FINDER, input_source=JAPANESE, variables=None):
        self.app = app
        self.input = input_source
        self.vars = dict(variables or {})


def first_match(manipulators, key, held_mods, env):
    for m in manipulators:
        if m.from_key != key:
            continue
        used = modifiers_match(m, held_mods)
        if used is None:
            continue
        if all(condition_match(c, env) for c in m.conditions):
            return m, used
    return None, None


class _Held:
    def __init__(self, manip, used, out_keys, t_down):
        self.manip = manip
        self.used = used            # mandatory で消費した修飾キー (出力からは外す)
        self.out_keys = out_keys    # 押しっぱなしにしている出力キー
        self.t_down = t_down
        self.alone = bool(manip and manip.to_if_alone)


class Simulator:
    """物理キーの押す/離すを時刻付きで流し込み、変数と出力を追う。"""

    def __init__(self, config, app=FINDER, input_source=JAPANESE):
        self.cfg = config
        self.env = Env(app, input_source)
        self.now = 0
        self.held = {}        # 物理キー -> _Held
        self.pending = []     # [(締め切り, manipulator)]
        self.output = []      # 出力した key_down: (key, frozenset(修飾キー))

    # --- 状態の見え方 ---
    def held_modifiers(self):
        mods = set()
        for h in self.held.values():
            for k in h.out_keys:
                if k in MODIFIER_KEYS:
                    mods.add(k)
        return mods

    def taps(self):
        """出力のうち修飾キー以外の押下を、'⌃⌥⌘f17' のような文字列で返す。"""
        sym = {"left_control": "⌃", "left_option": "⌥", "left_command": "⌘", "left_shift": "⇧",
               "right_control": "⌃", "right_option": "⌥", "right_command": "⌘", "right_shift": "⇧"}
        order = "⌃⌥⇧⌘"
        res = []
        for k, mods in self.output:
            if k in MODIFIER_KEYS:
                continue
            s = "".join(sorted({sym[m] for m in mods if m in sym}, key=order.index))
            res.append(s + k)
        return res

    # --- 時間 ---
    def advance(self, t):
        if t < self.now:
            raise ValueError("time went backwards")
        while True:
            due = [p for p in self.pending if p[0] <= t]
            if not due:
                break
            due.sort(key=lambda p: p[0])
            deadline, m = due[0]
            self.pending.remove(due[0])
            self.now = deadline
            self._run(m.delayed.get("to_if_invoked", []), set())
        self.now = t

    # --- 入力 ---
    def down(self, phys, t=None):
        self.advance(self.now if t is None else t)
        if phys in self.held:
            return  # キーリピートは扱わない
        key = self.cfg.simple.get(phys, phys)
        for h in self.held.values():
            h.alone = False
        m, used = first_match(self.cfg.manipulators, key, self.held_modifiers(), self.env)
        cancelled, self.pending = self.pending, []
        if m:
            out_keys = self._run(m.to, used, hold=True)
            h = _Held(m, used, out_keys, self.now)
        else:
            self.output.append((key, frozenset(self.held_modifiers())))
            h = _Held(None, set(), [key], self.now)
        for _, pm in cancelled:
            self._run(pm.delayed.get("to_if_canceled", []), set())
        if m and m.delayed:
            self.pending.append((self.now + m.delay_ms, m))
        self.held[phys] = h

    def up(self, phys, t=None):
        self.advance(self.now if t is None else t)
        h = self.held.pop(phys, None)
        if h is None or h.manip is None:
            return
        m = h.manip
        if h.alone and self.now - h.t_down <= m.alone_ms:
            self._run(m.to_if_alone, h.used)
        self._run(m.to_after_key_up, h.used)

    def tap(self, phys, t=None, hold_ms=30):
        start = self.now if t is None else t
        self.down(phys, start)
        self.up(phys, start + hold_ms)

    def release_all(self):
        for phys in list(self.held):
            self.up(phys)

    def idle(self, ms=5000):
        self.advance(self.now + ms)

    def _run(self, events, used, hold=False):
        held_keys = []
        base = self.held_modifiers() - set(used)
        for e in events:
            if "set_variable" in e:
                sv = e["set_variable"]
                self.env.vars[sv["name"]] = sv["value"]
                continue
            k = e.get("key_code") or e.get("pointing_button")
            if not k:
                continue
            mods = base | set(e.get("modifiers", []))
            self.output.append((k, frozenset(mods)))
            if hold:
                held_keys.append(k)
                if k in MODIFIER_KEYS:
                    base.add(k)
        return held_keys
