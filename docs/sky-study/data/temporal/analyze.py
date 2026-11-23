from pathlib import Path
from PIL import Image
import numpy as np
import csv,json
root=Path(__file__).resolve().parent
roi=(315,80,442,169)
metric={}; config={};timeline={}
for version in ('before','adopted'):
    d=root/version
    read=lambda f:json.loads((d/f).read_text(encoding='utf-8-sig'))
    meta=read('000019.json'); run=read('run-info.json')
    rec=meta['cloud_reconstruction']; taa=meta['cloud_anti_aliasing']
    assert meta['adapter']=='NVIDIA GeForce RTX 5080' and meta['frames']==20 and meta['nonfinite_samples']==0
    assert meta['quality'].lower()=='medium' and meta['classic_fast'] and meta['cloud_style']=='classic'
    assert rec['logical_size']==[320,180] and rec['phases']==4 and rec['active'] and rec['checker_frames']>=12
    assert taa['enabled'] and taa['history_available'] and len(list(d.glob('*.png')))==20
    assert (meta['width'],meta['height'])==(640,360) and not meta['texture_cloud_layers']['enabled']
    assert tuple(run['roi'])==roi
    timeline[version]=list(csv.DictReader((d/'timeline.csv').read_text(encoding='utf-8-sig').splitlines()))
    assert len(timeline[version])==20
    fields=('adapter','width','height','frames','simulation_seconds','weather','quality','cloud_style','classic_fast','sun_elevation','sun_azimuth','camera_position_m','cloud_settings','cloud_anti_aliasing','wind_offset_m')
    config[version]={k:meta[k] for k in fields}
    y=[]
    for i in range(8,20):
        with Image.open(d/f'{i:06d}.png') as im:
            assert im.size==(640,360)
            rgb=np.array(im.convert('RGB').crop(roi),dtype=np.float64)
        y.append(rgb @ np.array([.2126,.7152,.0722]))
    delta=np.abs(np.diff(np.stack(y),axis=0));size=delta.size
    metric[version]=dict(mean=float(delta.mean()),p95=float(np.percentile(delta,95)),
                         per_frame_pair_mean=[float(v) for v in delta.mean(axis=(1,2))],
                         adjacent_pair_count=delta.shape[0],sample_count=delta.size,
                         logical_size=rec['logical_size'],phases=rec['phases'],checker_frames=rec['checker_frames'],
                         full_refresh_frames=rec['full_refresh_frames'],taa=taa,
                         source_sha256=run['source_sha256'])
assert config['before']==config['adopted']
assert timeline['before']==timeline['adopted']
result=dict(roi_xyxy_half_open=roi,frame_indices_inclusive_zero_based=[8,19],discarded_frames=8,
            luma_weights_in_display_RGB=[.2126,.7152,.0722],units='absolute 8-bit display luma steps', metrics=metric,
            conditions=config['before'],all_20_weather_timeline_rows_identical=True,source_files=['before','adopted'])
# Write only the computed JSON to stdout so regenerating it leaves the guide intact.
print(json.dumps(result, ensure_ascii=False, indent=2))
