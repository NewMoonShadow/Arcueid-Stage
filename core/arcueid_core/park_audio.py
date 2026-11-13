"""Mix two fixed NPC interruptions at t=0 without changing the shared PCM route."""
import audioop
import io
import wave
from array import array


def simultaneous_wav(payloads: list[bytes]) -> bytes:
    tracks=[]; target_rate=32000
    for payload in payloads:
        with wave.open(io.BytesIO(payload),'rb') as wav:
            width=wav.getsampwidth(); channels=wav.getnchannels(); rate=wav.getframerate()
            frames=wav.readframes(wav.getnframes())
        if width!=2 or channels not in (1,2): raise ValueError('unsupported voice format')
        if channels==2: frames=audioop.tomono(frames,2,0.5,0.5)
        if rate!=target_rate: frames,_=audioop.ratecv(frames,2,1,rate,target_rate,None)
        tracks.append(array('h',frames))
    if len(tracks)!=2 or not all(tracks): raise ValueError('two nonempty voices required')
    mixed=[sum(track[i] if i<len(track) else 0 for track in tracks) for i in range(max(map(len,tracks)))]
    peak=max((abs(x) for x in mixed),default=0)
    gain=min(0.8,32760/max(peak,1))
    samples=array('h',(int(x*gain) for x in mixed))
    output=io.BytesIO()
    with wave.open(output,'wb') as wav:
        wav.setparams((1,2,target_rate,len(samples),'NONE','not compressed'))
        wav.writeframes(samples.tobytes())
    return output.getvalue()
