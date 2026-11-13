"""Compare production Rust boundary+ORT with official PyTorch HTDemucs, synthetic audio only.
Run after cargo build -p mornye-core --example demucs_boundary; model is explicit, never downloaded here.
"""
import argparse,json,subprocess,tempfile,hashlib
from pathlib import Path
import numpy as np

def main():
    p=argparse.ArgumentParser();p.add_argument('--model',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--driver',type=Path,default=Path('rust_backend/target/debug/examples/demucs_boundary'));args=p.parse_args()
    import torch,onnxruntime as ort
    from demucs.pretrained import get_model
    from demucs.apply import apply_model
    torch.set_num_threads(2)
    n=529200;t=np.arange(n,dtype=np.float64)/44100
    wave=np.stack([.2*np.sin(2*np.pi*223*t)+.03*np.sin(2*np.pi*71*t),.17*np.sin(2*np.pi*227*t)+.04*np.cos(2*np.pi*137*t)]).astype(np.float32)
    bag=get_model('htdemucs').cpu().eval()
    ref=torch.from_numpy(wave).mean(0);mean=ref.mean();std=ref.std().clamp(min=1e-6)
    with torch.inference_mode():expected=(apply_model(bag,((torch.from_numpy(wave)-mean)/std)[None],device='cpu',shifts=0,split=True,overlap=.25,num_workers=0)[0]*std+mean).numpy()
    del bag
    options=ort.SessionOptions();options.intra_op_num_threads=2;options.inter_op_num_threads=1;options.enable_cpu_mem_arena=False;options.enable_mem_pattern=False
    session=ort.InferenceSession(str(args.model),sess_options=options,providers=['CPUExecutionProvider'])
    with tempfile.TemporaryDirectory(prefix='libremusic-demucs-native-') as tmp:
        tmp=Path(tmp);pcm=tmp/'mix';wave.T.tofile(pcm);request=tmp/'request.json'
        def run(**kw):
            request.write_text(json.dumps({k:str(v) if isinstance(v,Path) else v for k,v in kw.items()}));return json.loads(subprocess.check_output([str(args.driver.resolve()),str(request)],text=True))
        compiled=run(action="metadata")["rust_source_sha256"]
        current=hashlib.sha256(Path("rust_backend/crates/core/src/audio_version_demucs.rs").read_bytes()).hexdigest()
        assert compiled==current, "Rebuild demucs_boundary from current Rust sources before validation"
        chunks=[]
        for j,offset in enumerate(range(0,n,257985)):
            w=tmp/f'{j}w';s=tmp/f'{j}s';f=tmp/f'{j}f';z=tmp/f'{j}t';out=tmp/f'{j}out'
            meta=run(action='prepare',input=pcm,offset=offset,wave=w,spec=s)
            freq,time=session.run(None,{'normalized_stereo_samples':np.fromfile(w,dtype='<f4').reshape(1,2,343980),'complex_spectrogram_channels':np.fromfile(s,dtype='<f4').reshape(1,4,2048,336)})
            freq.tofile(f);time.tofile(z);run(action='finish',freq=f,time=z,output=out);chunks.append(str(out))
        merged=tmp/'merged';run(action='merge',chunks=chunks,samples=n,mean=meta['mean'],std=meta['std'],output=merged);actual=np.fromfile(merged,dtype='<f4').reshape(4,2,n)
        report={'rust_source_sha256':compiled,'driver_sha256':hashlib.sha256(args.driver.read_bytes()).hexdigest(),'model_sha256':hashlib.sha256(args.model.read_bytes()).hexdigest(),'samples':n,'chunk_count':len(chunks),'source':'official htdemucs, shifts=0 overlap=.25','input':'deterministic synthetic stereo','sources':[]}
        for i,name in enumerate(['drums','bass','other','vocals']):
            a=actual[i].astype(float);b=expected[i].astype(float);relative=float(np.sqrt(np.mean((a-b)**2))/max(np.sqrt(np.mean(b*b)),1e-12));report['sources'].append({'name':name,'relative_rms_error':relative,'max_abs_error':float(np.max(np.abs(a-b))),'correlation':float(np.corrcoef(a.ravel(),b.ravel())[0,1])})
        report['pass']=all(x['relative_rms_error']<.01 and x['correlation']>.999 for x in report['sources']);args.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2));assert report['pass']
if __name__=='__main__':main()
