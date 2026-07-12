#!/usr/bin/env python3
"""Generate the Major & Minor scale practice books for Segno.

Emits, for each book, a MusicXML + a matching MIDI (generated from the SAME note
data so ingestion fuses 1:1) plus a sections.json (one saved section per scale).
Each scale: grand staff, both hands (LH two octaves below RH), 2 octaves up+down,
eighth notes then a final half note = exactly 4 bars of 4/4. Correct key signature
and spelling per key (e.g. F# major's E#).
"""
import struct, json, os

# Output into the bundled Scores/ folder (tools/../Woodshed/Scores).
SCORES_DIR = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "Woodshed", "Scores"))

# Letter index 0..6 = C D E F G A B, and their natural pitch-classes.
LETTER_PC = [0, 2, 4, 5, 7, 9, 11]
LETTER_NAME = ["C", "D", "E", "F", "G", "A", "B"]
SHARP_ORDER = [3, 0, 4, 1, 5, 2, 6]   # F C G D A E B
FLAT_ORDER  = [6, 2, 5, 1, 4, 0, 3]   # B E A D G C F

def key_alters(fifths):
    """Map letter-index -> alter (+1/-1) implied by the key signature."""
    alt = {}
    if fifths > 0:
        for l in SHARP_ORDER[:fifths]:
            alt[l] = 1
    elif fifths < 0:
        for l in FLAT_ORDER[:(-fifths)]:
            alt[l] = -1
    return alt

def note_at(tonic_letter, base_octave, degree, alter):
    """A note `degree` steps above the tonic. Returns (letter_idx, octave, alter, midi)."""
    li = (tonic_letter + degree) % 7
    octave = base_octave + (tonic_letter + degree) // 7
    midi = (octave + 1) * 12 + LETTER_PC[li] + alter
    return li, octave, alter, midi

def scale_notes(tonic_letter, fifths, base_octave, raise_deg_asc=(), raise_deg_desc=(),
                lower_from_natural=None):
    """Build the 29-note (2-octave up+down) note list for one scale.

    raise_deg_asc / raise_deg_desc: scale degrees (0-based, 0=tonic) whose alter is
    +1 above the base key spelling, for that direction (harmonic/melodic minor).
    """
    ksig = key_alters(fifths)
    def base_alter(deg):
        li = (tonic_letter + deg) % 7
        return ksig.get(li, 0)
    seq = []
    # Ascending degrees 0..14
    for d in range(0, 15):
        deg = d % 7
        alter = base_alter(deg) + (1 if deg in raise_deg_asc else 0)
        seq.append(note_at(tonic_letter, base_octave, d, alter))
    # Descending degrees 13..0
    for d in range(13, -1, -1):
        deg = d % 7
        alter = base_alter(deg) + (1 if deg in raise_deg_desc else 0)
        seq.append(note_at(tonic_letter, base_octave, d, alter))
    return seq   # 29 notes

# --- Scale catalogues (difficulty order = increasing accidentals) ---
# (name, tonic_letter, fifths)
MAJORS = [
    ("C major", 0, 0), ("G major", 4, 1), ("F major", 3, -1),
    ("D major", 1, 2), ("B♭ major", 6, -2), ("A major", 5, 3),
    ("E♭ major", 2, -3), ("E major", 2, 4), ("A♭ major", 5, -4),
    ("B major", 6, 5), ("D♭ major", 1, -5), ("F♯ major", 3, 6),
]
# Minor keys: (key name, tonic_letter, fifths of the minor key signature)
MINOR_KEYS = [
    ("A minor", 5, 0), ("E minor", 2, 1), ("D minor", 1, -1),
    ("B minor", 6, 2), ("G minor", 4, -2), ("F♯ minor", 3, 3),
    ("C minor", 0, -3), ("C♯ minor", 0, 4), ("F minor", 3, -4),
    ("G♯ minor", 4, 5), ("B♭ minor", 6, -5), ("E♭ minor", 2, -6),
]

def build_book(entries):
    """entries: list of (name, tonic_letter, fifths, mode, raise_asc, raise_desc).
    Returns list of dicts: {name, fifths, mode, rh:[29 notes], lh:[29 notes]}."""
    scales = []
    for (name, tl, fifths, mode, r_asc, r_desc) in entries:
        rh = scale_notes(tl, fifths, 4, r_asc, r_desc)
        lh = scale_notes(tl, fifths, 2, r_asc, r_desc)   # two octaves below
        scales.append(dict(name=name, fifths=fifths, mode=mode, rh=rh, lh=lh))
    return scales

def major_entries():
    return [(n, tl, f, "major", (), ()) for (n, tl, f) in MAJORS]

def minor_entries():
    out = []
    for (kname, tl, f) in MINOR_KEYS:
        base = kname.replace(" minor", "")
        # natural: no raises
        out.append((f"{base} minor (natural)", tl, f, "minor", (), ()))
        # harmonic: raise 7th (degree 6) both directions
        out.append((f"{base} minor (harmonic)", tl, f, "minor", (6,), (6,)))
        # melodic: ascending raise 6th & 7th (deg 5,6); descending natural
        out.append((f"{base} minor (melodic)", tl, f, "minor", (5, 6), ()))
    return out

# --- Rhythm layout: 29 notes -> 4 bars of 4/4 ---
# divisions per quarter = 2  => eighth = 1, half = 4, quarter = 2. 4/4 = 8 divisions/bar.
DIV = 2
EIGHTH, HALF = 1, 4
# note index -> (measure 0-3, is_half). Notes 0..27 eighths, note 28 = half.
def layout():
    lay = []
    beat = 0.0  # in quarters
    for i in range(29):
        dur = 2.0 if i == 28 else 0.5  # quarters
        measure = int(beat // 4)
        lay.append((measure, i == 28, beat))
        beat += dur
    return lay
LAYOUT = layout()

# =====================  MusicXML  =====================
def xml_note(li, octave, alter, dur_div, staff, is_chord=False):
    step = LETTER_NAME[li]
    acc = ""
    if alter == 1:  acc = "<accidental>sharp</accidental>"
    elif alter == 2: acc = "<accidental>double-sharp</accidental>"
    elif alter == -1: acc = "<accidental>flat</accidental>"
    elif alter == -2: acc = "<accidental>flat-flat</accidental>"
    elif alter == 0: acc = ""  # natural rendered only when needed; OSMD infers from key
    altxml = f"<alter>{alter}</alter>" if alter != 0 else ""
    typ = "half" if dur_div == HALF else "eighth"
    chord = "<chord/>" if is_chord else ""
    return (f'<note>{chord}<pitch><step>{step}</step>{altxml}<octave>{octave}</octave></pitch>'
            f'<duration>{dur_div}</duration><voice>{1 if staff==1 else 2}</voice>'
            f'<type>{typ}</type>{acc}<staff>{staff}</staff></note>')

def build_musicxml(scales, work_title):
    parts = []
    parts.append('<?xml version="1.0" encoding="UTF-8"?>')
    parts.append('<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 3.1 Partwise//EN" '
                 '"http://www.musicxml.org/dtds/partwise.dtd">')
    parts.append('<score-partwise version="3.1">')
    parts.append(f'<work><work-title>{work_title}</work-title></work>')
    parts.append('<part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>')
    parts.append('<part id="P1">')
    measure_no = 0
    for si, sc in enumerate(scales):
        for m in range(4):
            measure_no += 1
            attrs = ""
            direction = ""
            printel = ""
            if m == 0:
                printel = '<print new-system="yes"/>' if si > 0 else ''
                mode = sc["mode"]
                keyx = f'<key><fifths>{sc["fifths"]}</fifths><mode>{mode}</mode></key>'
                if si == 0:
                    attrs = (f'<attributes><divisions>{DIV}</divisions>{keyx}'
                             f'<time><beats>4</beats><beat-type>4</beat-type></time>'
                             f'<staves>2</staves>'
                             f'<clef number="1"><sign>G</sign><line>2</line></clef>'
                             f'<clef number="2"><sign>F</sign><line>4</line></clef></attributes>')
                else:
                    attrs = f'<attributes>{keyx}</attributes>'
                direction = ('<direction placement="above"><direction-type>'
                             f'<words>{sc["name"]}</words></direction-type></direction>')
            # notes for this measure: indices where LAYOUT measure == m
            idxs = [i for i in range(29) if LAYOUT[i][0] == m]
            mxml = [f'<measure number="{measure_no}">', printel, attrs, direction]
            # staff 1 (RH)
            for i in idxs:
                li, octave, alter, midi = sc["rh"][i]
                dur = HALF if LAYOUT[i][1] else EIGHTH
                mxml.append(xml_note(li, octave, alter, dur, 1))
            # backup to start of measure for staff 2
            total = sum(HALF if LAYOUT[i][1] else EIGHTH for i in idxs)
            mxml.append(f'<backup><duration>{total}</duration></backup>')
            for i in idxs:
                li, octave, alter, midi = sc["lh"][i]
                dur = HALF if LAYOUT[i][1] else EIGHTH
                mxml.append(xml_note(li, octave, alter, dur, 2))
            mxml.append('</measure>')
            parts.append("".join(mxml))
    parts.append('</part></score-partwise>')
    return "\n".join(parts)

# =====================  MIDI  =====================
def vlq(n):
    out = bytearray([n & 0x7F]); n >>= 7
    while n:
        out.insert(0, (n & 0x7F) | 0x80); n >>= 7
    return bytes(out)

def track_bytes(events):
    """events: list of (abs_tick, status, d1, d2). Returns MTrk chunk."""
    events = sorted(events, key=lambda e: e[0])
    data = bytearray()
    last = 0
    for (tick, status, d1, d2) in events:
        data += vlq(tick - last); last = tick
        data += bytes([status, d1, d2])
    data += vlq(0) + bytes([0xFF, 0x2F, 0x00])   # end of track
    return b"MTrk" + struct.pack(">I", len(data)) + bytes(data)

TPQ = 480
def build_midi(scales):
    # TWO tracks only (RH, LH) — the app assigns hands from exactly two tracks by
    # average pitch, so a separate empty conductor track would break that. Tempo +
    # time-signature meta ride at the front of the RH track.
    def hand_events(which, channel):
        events = []
        base_tick = 0
        for sc in scales:
            for i in range(29):
                li, octave, alter, midi = sc[which][i]
                beat = LAYOUT[i][2]
                dur_q = 2.0 if LAYOUT[i][1] else 0.5
                on = base_tick + int(round(beat * TPQ))
                off = base_tick + int(round((beat + dur_q) * TPQ))
                events.append((on, 0x90 | channel, midi, 80))
                events.append((off, 0x80 | channel, midi, 0))
            base_tick += 16 * TPQ   # 4 bars of 4/4 = 16 quarter-beats
        return events

    # RH track with meta prepended (build bytes manually to place meta at tick 0).
    rh_ev = sorted(hand_events("rh", 0), key=lambda e: e[0])
    data = bytearray()
    data += vlq(0) + bytes([0xFF, 0x51, 0x03]) + struct.pack(">I", 600000)[1:]  # 100 BPM
    data += vlq(0) + bytes([0xFF, 0x58, 0x04, 4, 2, 24, 8])                      # 4/4
    last = 0
    for (tick, status, d1, d2) in rh_ev:
        data += vlq(tick - last); last = tick
        data += bytes([status, d1, d2])
    data += vlq(0) + bytes([0xFF, 0x2F, 0x00])
    rh = b"MTrk" + struct.pack(">I", len(data)) + bytes(data)

    lh = track_bytes(hand_events("lh", 1))
    header = b"MThd" + struct.pack(">IHHH", 6, 1, 2, TPQ)
    return header + rh + lh

# =====================  sections.json  =====================
import uuid
def build_sections(scales):
    out = []
    for si, sc in enumerate(scales):
        start = si * 4 + 1
        out.append(dict(id=str(uuid.uuid4()).upper(), name=sc["name"], start=start, end=start + 3))
    return out

def write_book(entries, base, title):
    scales = build_book(entries)
    os.makedirs(SCORES_DIR, exist_ok=True)
    with open(os.path.join(SCORES_DIR, base + ".musicxml"), "w") as f:
        f.write(build_musicxml(scales, title))
    with open(os.path.join(SCORES_DIR, base + ".mid"), "wb") as f:
        f.write(build_midi(scales))
    with open(os.path.join(SCORES_DIR, base + "-sections.json"), "w") as f:
        json.dump(build_sections(scales), f, indent=2)
    total_notes = sum(29 for _ in scales) * 2
    print(f"{base}: {len(scales)} scales, {len(scales)*4} bars, {total_notes} MIDI notes")

write_book(major_entries(), "MajorScales", "Major Scales")
write_book(minor_entries(), "MinorScales", "Minor Scales")
print("done")
