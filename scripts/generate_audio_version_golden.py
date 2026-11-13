#!/usr/bin/env python3
"""Generate numeric goldens using the frozen Python comparator (numpy/scipy).

Pass --reference to the validated experiment's code directory. Music and models
are not required: the reference receives reproducible synthetic float32 audio.
"""
import argparse
import hashlib
import importlib
import json
import math
from pathlib import Path
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--reference', type=Path, required=True)
parser.add_argument('--output', type=Path, default=Path('rust_backend/crates/core/tests/fixtures/audio_version_golden.json'))
args = parser.parse_args()
sys.path.insert(0, str(args.reference))
import numpy as np
import soundfile as sf
core = importlib.import_module('core_frozen')
alignment = importlib.import_module('alignment_v8_1')
primary = importlib.import_module('frozen_v5_4')

def audio(seconds):
    state = 0x12345678
    values = []
    for i in range(16000 * seconds):
        state = (1664525 * state + 1013904223) & 0xffffffff
        t = i / 16000
        envelope = .25 + .75 * (.5 + .5 * math.sin(2 * math.pi * .47 * t))
        values.append(envelope * (.2 * math.sin(2 * math.pi * (180 + 10 * t) * t)
                                 + .08 * math.sin(2 * math.pi * (700 + 2 * t * t) * t)
                                 + .14 * (state / 4294967296 - .5)))
    return np.asarray(values, dtype=np.float32)

a = audio(36)
feature = core.feature(a[:32000])
indices = [0, 1, 17, len(feature) - 1]
result = {'reference_sha256': {name: hashlib.sha256((args.reference / name).read_bytes()).hexdigest()
                             for name in ['core_frozen.py', 'alignment_v8_1.py', 'frozen_v5_4.py']},
          'generator': 'LCG seed0x12345678, stereo-independent chirp+noise, see generator and Rust test',
          'features': [{'index': i, 'values': feature[i].tolist()} for i in indices],
          'filter': core.sig.sosfilt(core.sig.butter(3, [150, 6000], btype='bandpass', fs=16000, output='sos'), a[:32]).tolist(),
          'cases': []}
with tempfile.TemporaryDirectory() as directory:
    tmp = Path(directory)
    sf.write(tmp / 'a.wav', a, 16000, subtype='FLOAT')
    for name in ['gain_delay', 'mute_delay']:
        b = a.copy()
        if name == 'mute_delay': b[round(18.5*16000):round(19.1*16000)] = 0
        b = np.concatenate([np.zeros(1217, dtype=np.float32), b * np.float32(.6)])
        aligned = alignment.choose_low(a,b)
        assert aligned['decision'] == 'aligned', aligned
        sf.write(tmp / 'b.wav', b, 16000, subtype='FLOAT')
        primary.metrics(tmp / 'a.wav', tmp / 'b.wav', aligned['offset'], tmp / 'metrics.npz')
        features = np.load(tmp / 'metrics.npz')
        decision = primary.decide(features)
        result['cases'].append({'name':name,'offset':aligned['offset'],
                                'anchors':aligned['accepted_hypotheses'][0]['anchors'],
                                'usable_bands':int(sum(features['usable_bands'])),
                                'events':decision['events']})
args.output.parent.mkdir(exist_ok=True, parents=True)
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(args.output)
