"""Split the exact official HTDemucs into native FFT boundary + real ONNX trunk.

This is an export experiment, not an Android implementation or substitute model.
"""
from pathlib import Path
import argparse,inspect,textwrap,types,hashlib,json,time,resource
import numpy as np
import torch
from demucs.pretrained import get_model
from demucs.htdemucs import HTDemucs
from export_wavlm_mobile import sha

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--audio',type=Path,required=True);args=parser.parse_args();args.output.mkdir(exist_ok=True,parents=True);torch.set_num_threads(2);torch.backends.mha.set_fastpath_enabled(False);bag=get_model('hf://htdemucs').cpu().eval();assert len(bag.models)==1;model=bag.models[0];assert model.cac
 import subprocess
 length=int(model.segment*model.samplerate);raw=subprocess.check_output(['ffmpeg','-v','error','-i',str(args.audio),'-t',str(float(model.segment)),'-ac','2','-ar',str(model.samplerate),'-f','f32le','-']);wave=torch.from_numpy(np.frombuffer(raw,dtype='<f4').reshape(-1,2).T.copy());ref=wave.mean(0);mean=ref.mean();std=ref.std().clamp(min=1e-6);mix=((wave-mean)/std)[None];assert mix.shape[-1]==length
 with torch.inference_mode():
  spectrum=model._spec(mix);spec=model._magnitude(spectrum);expected=model(mix)
 # Use original installed forward implementation and separate only the complex FFT boundary.
 original=inspect.getsource(HTDemucs.forward);prefix=original[:original.index('        # to cpu as mps')];prefix=prefix.replace('def forward(self, mix):','def forward(self, mix, spectrogram):').replace('z = self._spec(mix)','z = spectrogram').replace('mag = self._magnitude(z).to(mix.device)','mag = z');prefix+='        xt = xt.view(B, S, -1, training_length)\n        xt = xt * stdt[:, None] + meant[:, None]\n        return x, xt\n';scope={};exec(textwrap.dedent(prefix),HTDemucs.forward.__globals__,scope);model.forward=types.MethodType(scope['forward'],model)
 with torch.inference_mode():
  freq,timebranch=model(mix,spec);reconstructed=model._ispec(model._mask(spectrum,freq),length)+timebranch
 error=float(torch.max(torch.abs(reconstructed-expected)));assert torch.allclose(reconstructed,expected,atol=1e-5,rtol=1e-5),error
 (args.output/'split_forward_source.py').write_text(textwrap.dedent(prefix));path=args.output/'htdemucs-trunk-fp32.onnx';start=time.monotonic();print('SPLIT TORCH EQUIVALENCE',error,'input',tuple(mix.shape),tuple(spec.shape),'outputs',tuple(freq.shape),tuple(timebranch.shape),flush=True)
 torch.onnx.export(model,(mix,spec),str(path),input_names=['normalized_stereo_samples','complex_spectrogram_channels'],output_names=['source_complex_spectrogram_channels','source_time_branch'],opset_version=17,dynamo=False,external_data=False);export_seconds=time.monotonic()-start;print('EXPORTED',path.stat().st_size,'seconds',export_seconds,flush=True)
 import onnx,onnxruntime as ort
 onnx.checker.check_model(str(path));options=ort.SessionOptions();options.intra_op_num_threads=2;options.inter_op_num_threads=1;session=ort.InferenceSession(str(path),sess_options=options,providers=['CPUExecutionProvider']);start=time.monotonic();actual_freq,actual_time=session.run(None,{'normalized_stereo_samples':mix.numpy(),'complex_spectrogram_channels':spec.numpy()});seconds=time.monotonic()-start
 with torch.inference_mode():actual=model._ispec(model._mask(spectrum,torch.from_numpy(actual_freq)),length)+torch.from_numpy(actual_time)
 err=float(torch.max(torch.abs(actual-expected)));relative=float(torch.sqrt(torch.mean((actual-expected)**2))/torch.sqrt(torch.mean(expected**2)));corr=float(np.corrcoef(actual.numpy().ravel(),expected.numpy().ravel())[0,1]);report={'source_model':'demucs htdemucs, single HTDemucs inside BagOfModels','source_forward_sha256':hashlib.sha256(original.encode()).hexdigest(),'model_sha256':sha(path),'bytes':path.stat().st_size,'parameters':sum(p.numel() for p in model.parameters()),'samplerate':model.samplerate,'segment_samples':length,'nfft':model.nfft,'hop_length':model.hop_length,'source_order':model.sources,'inputs':{i.name:{'type':i.type,'shape':i.shape} for i in session.get_inputs()},'outputs':{i.name:{'type':i.type,'shape':i.shape} for i in session.get_outputs()},'split_torch_max_abs_error':error,'ort_reconstructed_max_abs_error':err,'ort_reconstructed_relative_rms_error':relative,'ort_reconstructed_correlation':corr,'ort_seconds':seconds,'export_seconds':export_seconds,'host_peak_rss_bytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'limits':'Exact real-valued neural trunk exported. Native STFT/iSTFT, chunk overlap/add, padding, outer waveform normalization must match Demucs. Host reconstruction still uses PyTorch FFT, not Android. No claim of mobile memory/time or complete direction equivalence.'};(args.output/'demucs-export-report.json').write_text(json.dumps(report,indent=2));print('DEMUCS MOBILE EXPORT COMPLETE',report,flush=True)
if __name__=='__main__':main()
