from pathlib import Path
import hashlib, json, sys
import numpy as np
from PIL import Image
script_dir=Path(__file__).resolve().parent
sys.path.insert(0, str(script_dir.parent/'photo-analysis'))
from measure_crown import measure
def rgb(path):
    with Image.open(path) as source:
        return np.array(source.convert('RGB'))
def alpha(path):
    return rgb(path)[:,:,0].astype(np.float32)/255
def verify_pair(a,b):
    for k in ('adapter','width','height','weather','quality','cloud_style','camera_position_m','frames','simulation_seconds','wind_offset_m','sun_elevation','sun_azimuth','cloud_settings','cloud_anti_aliasing','texture_cloud_layers','cloud_reconstruction','texture_view'):
        assert a[k]==b[k],k
    assert a.get('world')==b.get('world'), 'world'
    assert a['nonfinite_samples']==b['nonfinite_samples']==0
if __name__=='__main__':
    import argparse
    ap=argparse.ArgumentParser(description='Compare the native sky study captures and the higher-sample ray integration checks.')
    ap.add_argument('captures',type=Path)
    ap.add_argument('output',type=Path)
    args=ap.parse_args();p=args.captures
    report={'camera_comparisons':{},'crown_profiles':{},'raw_transmission':{},'integration':{}}
    for name,b,a in [('ridge','ridge-previous','ridge-final'),('partly','partly-previous','partly-final'),('ground','ground-old','ground-final')]:
        reads=[json.loads((p/(n+'.json')).read_text(encoding='utf-8-sig')) for n in (b,a)]
        verify_pair(*reads)
        images=[rgb(p/(n+'.png')) for n in (b,a)]
        delta=np.abs(images[1].astype(np.int16)-images[0].astype(np.int16))
        report['camera_comparisons'][name]={'before':b,'after':a,'size':list(images[0].shape[1::-1]),'weather':reads[0]['weather'],'frames':reads[0]['frames'],'camera':reads[0]['camera_position_m'],'mean_abs_rgb_255':round(float(delta.mean()),4),'nonfinite_samples':0}
    for n in ('ridge-previous','ridge-final'):
        report['crown_profiles'][n]={str(w):measure(p/(n+'.png'),[1520,384,2240,687],w)[0] for w in [128,256]}
    pair=[p/(n+'-t.png') for n in ('ridge-previous','ridge-final')]
    verify_pair(*(json.loads(pp.with_suffix('.json').read_text()) for pp in pair))
    for n,pp in zip(['before','after'],pair):
        t=alpha(pp)
        report['raw_transmission'][n]={}
        for label,(x0,y0,x1,y1) in {'gap':(1510,620,1770,860),'crown':(1320,365,2500,1080),'sky':(0,0,3840,1000)}.items():
            region=t[y0:y1,x0:x1]
            report['raw_transmission'][n][label]={'xyxy':[x0,y0,x1,y1],'mean_T':round(float(region.mean()),5),'fraction_T_gt_090':round(float((region>.9).mean()),5),'fraction_T_lt_010':round(float((region<.1).mean()),5)}
    for s in ['old','new']:
        names=['ridge-'+s+'-'+i for i in ('norm','ref')]
        verify_pair(*(json.loads((p/(n+'.json')).read_text()) for n in names))
        a,b=[alpha(p/(n+'.png')) for n in names]
        for label,region in [('full',np.s_[:,:]),('cloud',np.s_[60:178,220:420])]:
            d=np.abs(a[region]-b[region]); report['integration'][s+'_'+label]={'mean_abs_T':round(float(d.mean()),6),'p95_abs_T':round(float(np.percentile(d,95)),6),'fraction_abs_T_over_005':round(float((d>.05).mean()),6)}
    report['png_sha256']={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(p.glob('*.png')) if f.stem in {i for v in report['camera_comparisons'].values() for i in [v['before'],v['after']]} | {'ridge-previous-t','ridge-final-t','ridge-old-norm','ridge-old-ref','ridge-new-norm','ridge-new-ref'}}
    control = [rgb(p/('deck-'+n+'.png')) for n in ('before','after')]
    report['overcast_control'] = {'same_rgb_pixels':int(np.all(control[0]==control[1],axis=-1).sum()),'pixels':int(np.prod(control[0].shape[:2]))}
    args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
