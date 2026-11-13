"""Reproducible independent NumPy oracle; no audio/model assets enter the repository."""
import numpy as np, math, json
from pathlib import Path
NFFT=4096;HOP=1024;SEGMENT=343980;SR=44100;FRAMES=336

def hann():return (.5-.5*np.cos(2*np.pi*np.arange(NFFT,dtype=np.float64)/NFFT)).astype(np.float32)
def spec(x):
 length=x.shape[-1];frames=math.ceil(length/HOP);pad=3*HOP//2
 x=np.pad(x,[(0,0)]*(x.ndim-1)+[(pad,pad+frames*HOP-length)],mode='reflect');x=np.pad(x,[(0,0)]*(x.ndim-1)+[(NFFT//2,NFFT//2)],mode='reflect');windows=np.lib.stride_tricks.sliding_window_view(x,NFFT,axis=-1)[...,::HOP,:]*hann();z=np.fft.rfft(windows,axis=-1,norm='ortho');z=np.swapaxes(z,-1,-2);return np.asarray(z[...,:-1,2:2+frames],dtype=np.complex64)
def channels(z):
 real=np.stack([z.real,z.imag],axis=2);return real.reshape(z.shape[0],z.shape[1]*2,z.shape[2],z.shape[3]).astype(np.float32)
def source_complex(x):
 batch,sources,_,freqs,frames=x.shape;return (x.reshape(batch,sources,2,2,freqs,frames)[:,:,:,0]+1j*x.reshape(batch,sources,2,2,freqs,frames)[:,:,:,1]).astype(np.complex64)
def ispec(z,length):
 z=np.pad(z,[(0,0)]*(z.ndim-2)+[(0,1),(2,2)]);time=np.fft.irfft(z,n=NFFT,axis=-2,norm='ortho').astype(np.float32)*hann()[:,None];frames=z.shape[-1];out=np.zeros(z.shape[:-2]+((frames-1)*HOP+NFFT,),np.float32);denom=np.zeros(out.shape[-1],np.float32);w2=hann()**2
 for f in range(frames):out[...,f*HOP:f*HOP+NFFT]+=time[...,f];denom[f*HOP:f*HOP+NFFT]+=w2
 out/=np.maximum(denom,np.float32(1e-12));outer_length=HOP*math.ceil(length/HOP)+3*HOP;out=out[...,NFFT//2:NFFT//2+outer_length];pad=3*HOP//2;return out[...,pad:pad+length]

n=np.arange(SEGMENT,dtype=np.uint64)
u=((n+1)*1664525+1013904223)%4294967296
wave=np.stack([.2*np.sin(n.astype(np.float64)*.013)+.01*(u.astype(np.float64)/2147483648.-1),.15*np.cos(n.astype(np.float64)*.027)]).astype(np.float32)[None]
z=spec(wave);encoded=channels(z);restored=ispec(z,SEGMENT)
points=[(c,f,t) for c in range(4) for f in [0,1,17,1000,2047] for t in [0,1,127,335]]
report={'oracle':'NumPy orthonormal FFT, exact HTDemucs reflection/Hann/crop','spectrum':[{'channel':c,'frequency':f,'frame':t,'value':float(encoded[0,c,f,t])} for c,f,t in points],'inverse':[{'channel':c,'sample':i,'value':float(restored[0,c,i])} for c in range(2) for i in [0,1,1024,34397,123456,343978,343979]]}
Path(__file__).resolve().parent.parent.joinpath('rust_backend/crates/core/tests/fixtures/audio_version_demucs_golden.json').write_text(json.dumps(report,indent=2)+'\n')

def frame_db(x):
    p=np.pad(x*x,(1102,1102),mode='symmetric'); prefix=np.concatenate(([0.],np.cumsum(p,dtype=np.float64)))
    return 10*np.log10(np.maximum(((prefix[2205:]-prefix[:-2205])/2205)[::441],1e-12))
def scenario(kind):
    n=44100*12;t=np.arange(n)/44100
    voice=(.16*np.sin(2*np.pi*223*t)).astype(np.float32);music=(.12*np.sin(2*np.pi*137*t)).astype(np.float32)
    a=voice.copy();b=(voice*.7).astype(np.float32);au=music.copy();bu=(music*.7).astype(np.float32)
    intervals=[(4.,4.4)]+([(8.,8.4)] if kind=='mixed' else [])
    for j,(l,r) in enumerate(intervals):
        sl=slice(round(l*44100),round(r*44100))
        if j==1:a[sl]*=.1
        elif kind=='whole':b[sl]=0;bu[sl]=0
        else:b[sl]*=.1
    da,db,ma,mb=map(frame_db,[a.astype(float),b.astype(float),(a+au).astype(float),(b+bu).astype(float)])
    ft=np.arange(len(da))*.01;outside=np.ones(len(ft),bool)
    for l,r in intervals:outside&=~((ft>=l-.15)&(ft<=r+.15))
    mask=outside&(da>=np.quantile(da,.9)-15)&(db>=np.quantile(db,.9)-15)
    base=np.median((db-da)[mask]);mixmask=outside&(ma>=np.quantile(ma,.9)-20)&(mb>=np.quantile(mb,.9)-20);mixbase=np.median((mb-ma)[mixmask]);rows=[]
    for l,r in intervals:
        select=(ft>=l)&(ft<=r);sl=slice(round(l*44100),round(r*44100));rms=lambda x:20*np.log10(max(np.sqrt(np.mean(x[sl].astype(float)**2)),1e-12))
        rows.append({'local':float(np.median((db-da)[select])-base),'whole':float(np.median((mb-ma)[select])-mixbase),'balance':float((rms(b)-rms(bu))-(rms(a)-rms(au)))})
    return rows
report['direction']={kind:scenario(kind) for kind in ['vocal','whole','mixed']}
Path(__file__).resolve().parent.parent.joinpath('rust_backend/crates/core/tests/fixtures/audio_version_demucs_golden.json').write_text(json.dumps(report,indent=2)+'\n')

# Optional pinned neural trunk output golden. No model is downloaded by this script.
if __name__ == '__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('--demucs-model',type=Path);args=parser.parse_args()
    if args.demucs_model:
        import onnxruntime as ort
        options=ort.SessionOptions();options.intra_op_num_threads=2;options.inter_op_num_threads=1
        session=ort.InferenceSession(str(args.demucs_model),sess_options=options,providers=['CPUExecutionProvider'])
        outputs=session.run(None,{'normalized_stereo_samples':np.zeros((1,2,SEGMENT),np.float32),'complex_spectrogram_channels':np.zeros((1,4,2048,FRAMES),np.float32)})
        rows={}
        for name,values in zip(['frequency','time'],outputs):
            flat=values.ravel();indices=[0,1,100,10000,len(flat)//2,len(flat)-1];rows[name]=[{'index':i,'value':float(flat[i])} for i in indices]
        Path(__file__).resolve().parent.parent.joinpath('android/app/src/test/resources/audio_version_demucs_synthetic.json').write_text(json.dumps(rows,indent=2)+'\n')
