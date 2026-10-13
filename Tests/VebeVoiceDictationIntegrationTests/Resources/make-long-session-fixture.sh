#!/bin/bash
# Generate synthetic, non-private speech with unique start/middle/end markers.
set -euo pipefail
fixture_dir=$(mktemp -d /private/tmp/vebevoice-speech.XXXXXX)
trap 'rm -rf "$fixture_dir"' EXIT
say -v Samantha --file-format=WAVE --data-format=LEI16@16000 -o "$fixture_dir/start.wav" 'The lighthouse marks the beginning of this recording. We are checking that every sentence is preserved.'
say -v Samantha --file-format=WAVE --data-format=LEI16@16000 -o "$fixture_dir/body.wav" 'Today I am planning a walk through the garden. The weather is pleasant and the trees are full of birds. After lunch I will read a book and write a letter to a friend. Tomorrow I will visit the library and choose a new story. These ordinary sentences help us check a longer recording.'
say -v Samantha --file-format=WAVE --data-format=LEI16@16000 -o "$fixture_dir/middle.wav" 'The notebook marks the middle of this recording. Five minutes have passed and the conversation continues.'
say -v Samantha --file-format=WAVE --data-format=LEI16@16000 -o "$fixture_dir/end.wav" 'Sunflowers mark the end of this recording. The entire ten minute session is now complete.'
python3 - "$fixture_dir" <<'PY'
from pathlib import Path
import sys, wave
root=Path(sys.argv[1])
def read(name):
    with wave.open(str(root / (name+'.wav')), 'rb') as f:
        assert (f.getnchannels(), f.getsampwidth(), f.getframerate()) == (1,2,16000)
        data=f.readframes(f.getnframes())
        assert len(data) > 0, 'Speech synthesis returned no audio; run with access to macOS speech services'
        return data
start,body,middle,end=map(read,['start','body','middle','end'])
audio=bytearray(600*16000*2)
def fill(lo,hi):
    while lo + len(body) <= hi:
        audio[lo:lo+len(body)]=body
        lo += len(body)
audio[:len(start)]=start
mid=300*16000*2
audio[mid:mid+len(middle)]=middle
end_pos=len(audio)-len(end)
audio[end_pos:]=end
fill(len(start),mid)
fill(mid+len(middle),end_pos)
with wave.open('/private/tmp/vebevoice-long-session.wav','wb') as f:
    f.setparams((1,2,16000,0,'NONE','not compressed'))
    f.writeframes(audio)
print('Created /private/tmp/vebevoice-long-session.wav (600 seconds)')
PY
