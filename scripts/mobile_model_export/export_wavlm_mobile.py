"""Export exact WavLM layer-6 representation for fixed 12-second mobile inference.

Arguments bind the pinned source model and optional existing experimental cases;
no music or weights are uploaded to a remote service.
"""
from pathlib import Path
import argparse,copy,hashlib,json,time,resource,platform,importlib.metadata
import numpy as np
import torch
from transformers import WavLMModel
REVISION='4c66d4806a428f2e922ccfa1a962776e232d487b'
WEIGHT_SHA256='3bb273a6ace99408b50cfc81afdbb7ef2de02da2eab0234e18db608ce692fe51'
SAMPLES=192000

def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
 return h.hexdigest()
def normalize(x):
 x=np.asarray(x,dtype=np.float32);return (x-x.mean(axis=-1,keepdims=True))/np.sqrt(x.var(axis=-1,keepdims=True)+1e-7)
class Layer6(torch.nn.Module):
 def __init__(self,model):super().__init__();self.model=model
 def forward(self,normalized_samples):
  # All samples are valid, including deliberate zero padding inside the normalized clip.
  return self.model(normalized_samples,attention_mask=None,output_hidden_states=False).last_hidden_state

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--snapshot',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--research-dir',type=Path);args=parser.parse_args();args.output.mkdir(exist_ok=True,parents=True)
 assert args.snapshot.name==REVISION;assert sha(args.snapshot/'pytorch_model.bin')==WEIGHT_SHA256
 torch.set_num_threads(2);torch.manual_seed(0);model=WavLMModel.from_pretrained(str(args.snapshot),local_files_only=True,use_safetensors=False,attn_implementation='eager').cpu().eval();full_parameters=sum(p.numel() for p in model.parameters())
 contexts=[]
 if args.research_dir:
  import sys
  sys.path.insert(0,str(args.research_dir));import core_frozen as core
  data=json.loads((args.research_dir/'v7-evaluation.json').read_text())['cases']
  for name in ['real-mukka','real-gone_mumble','queen-mp3_32','aquarium-mp3_32']:
   r=next((r for r in data if r['id']==name or r['id'].endswith(name)),None)
   if r is None:continue
   e=max(r['events'],key=lambda x:x.get('content_peak_excess',0)) if r.get('events') else None
   if not e:continue
   start=e['context_B_start'];a=core.decode(Path(r['reference']));b=core.decode(Path(r['candidate']));x=normalize(np.stack([core.extract(a,start+r['offset'],12),core.extract(b,start,12)]));contexts.append({'id':r['id'],'x':x,'start_B':start,'offset':r['offset'],'all_events':r['events'],'source_sha256':{'A':sha(Path(r['reference'])),'B':sha(Path(r['candidate']))}})
 if not contexts:contexts=[{'id':'seeded_random_input','x':normalize(np.random.default_rng(0).normal(size=(2,SAMPLES)).astype(np.float32))}]
 references=[]
 for c in contexts:
  with torch.inference_mode():references.append(model(torch.from_numpy(c['x']),attention_mask=torch.ones_like(torch.from_numpy(c['x']),dtype=torch.long),output_hidden_states=True).hidden_states[6].numpy())
 del model.encoder.layers[6:]
 # Removing weight parametrization materializes the exact current convolution weights.
 if torch.nn.utils.parametrize.is_parametrized(model.encoder.pos_conv_embed.conv,'weight'):torch.nn.utils.parametrize.remove_parametrizations(model.encoder.pos_conv_embed.conv,'weight',leave_parametrized=True)
 wrapped=Layer6(model).eval();pruned_parameters=sum(p.numel() for p in model.parameters());rows=[]
 for c,expected in zip(contexts,references):
  with torch.inference_mode():actual=np.concatenate([wrapped(torch.from_numpy(x[None])).numpy() for x in c['x']],axis=0)
  err=float(np.max(np.abs(actual-expected)));rows.append({'id':c['id'],'pruned_and_single_batch_max_abs_error':err});assert np.allclose(actual,expected,atol=1e-4,rtol=1e-4),(c['id'],err)
 print('PRUNING EQUIVALENCE',rows,'params',full_parameters,'->',pruned_parameters,flush=True)
 modelpath=args.output/'wavlm-layer6-fp32.onnx';start=time.monotonic()
 torch.onnx.export(wrapped,(torch.from_numpy(contexts[0]['x'][:1]),),str(modelpath),input_names=['normalized_samples'],output_names=['layer6_hidden_states'],opset_version=17,dynamo=False,external_data=False)
 export_seconds=time.monotonic()-start;print('EXPORTED',modelpath,modelpath.stat().st_size,'seconds',export_seconds,flush=True)
 import onnx,onnxruntime as ort
 onnx.checker.check_model(str(modelpath));options=ort.SessionOptions();options.intra_op_num_threads=2;options.inter_op_num_threads=1;session=ort.InferenceSession(str(modelpath),sess_options=options,providers=['CPUExecutionProvider']);timings=[]
 for c,expected,row in zip(contexts,references,rows):
  start=time.monotonic();actual=np.concatenate([session.run(['layer6_hidden_states'],{'normalized_samples':np.asarray(x[None],dtype=np.float32)})[0] for x in c['x']],axis=0);timings.append(time.monotonic()-start);row['ort_max_abs_error']=float(np.max(np.abs(actual-expected)));row['ort_relative_rms_error']=float(np.sqrt(np.mean((actual-expected)**2))/np.sqrt(np.mean(expected**2)));row['ort_shape']=list(actual.shape);row['source_sha256']=c.get('source_sha256');assert np.allclose(actual,expected,atol=5e-4,rtol=5e-4),(c['id'],row)
  np.savez_compressed(args.output/(c['id']+'-equivalence.npz'),input=c['x'],torch_layer6=expected,ort_layer6=actual)
 report={'model_revision':REVISION,'original_weights_sha256':WEIGHT_SHA256,'onnx_sha256':sha(modelpath),'onnx_size_bytes':modelpath.stat().st_size,'full_parameters':full_parameters,'pruned_parameters':pruned_parameters,'input':{'name':'normalized_samples','dtype':'float32','shape':[1,SAMPLES]},'output':{'name':'layer6_hidden_states','dtype':'float32','shape':[1,599,768]},'sample_rate':16000,'stride_samples':320,'receptive_samples':400,'normalization':'Clip float32 mean/variance (population), (x-mean)/sqrt(var+1e-7), independently for A/B. Fixed12s extraction; padding zeros included BEFORE normalization. No model attention mask. Do not zero-pad already normalized clips.','opset':17,'providers':session.get_providers(),'export_seconds':export_seconds,'ort_two_role_seconds':timings,'host':platform.platform(),'host_peak_rss_bytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'versions':{n:importlib.metadata.version(n) for n in ['torch','transformers','onnx','onnxruntime']},'equivalence':rows,'limits':'Host CPU ONNX numerical equivalence only, not Android memory/performance. FP32 only; quantization not evaluated. Model weights/audio not embedded into app.'}
 (args.output/'wavlm-export-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print('WAVLM MOBILE EXPORT COMPLETE',json.dumps(report),flush=True)
if __name__=='__main__':main()
