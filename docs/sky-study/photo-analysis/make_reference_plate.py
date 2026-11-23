from pathlib import Path
import hashlib
import json
from PIL import Image, ImageDraw, ImageFont
from measure_crown import measure

HERE=Path(__file__).resolve().parent
DATA=[
    ("atlantic", "並積雲 / 大西洋", "Ralph F. Kresge / NOAA・NWS", [245,202,545,326],256),
    ("congestus", "雄大雲 / 昼光", "Cruse/Crowley / NOAA・NWS", [74,128,361,238],256),
    ("hawaii", "晴天積雲 / ハワイ", "NOAA Photo Library", [187,45,292,122],96),
]
def render():
    page=Image.new("RGB",(1320,783),(21,31,43));d=ImageDraw.Draw(page)
    font_dir=Path("C:/Windows/Fonts")
    heading=ImageFont.truetype(str(font_dir/"meiryob.ttc"),32)
    title=ImageFont.truetype(str(font_dir/"meiryob.ttc"),24)
    label=ImageFont.truetype(str(font_dir/"meiryo.ttc"),17)
    small=ImageFont.truetype(str(font_dir/"meiryo.ttc"),15)
    d.text((20,9),"実写の積雲で輪郭を読む",font=heading,fill="#f3f7fa")
    d.text((21,59),"上段の枠を拡大。中段は元の色、下段は色の閾値を変えて抽出した上縁（水色35%、黄50%、紫65%）。",font=label,fill="#c4d2df")
    out={}
    for i,(key,name,credit,roi,width) in enumerate(DATA):
        x=22+i*434
        file=HERE/"references"/(key+".jpg")
        with Image.open(file) as o:
            whole=o.convert("RGB")
        v,tile,lines=measure(file,roi,width)
        v["sha256"]=hashlib.sha256(file.read_bytes()).hexdigest()
        v["source_size"]=whole.size
        out[key]=v
        d.text((x,100),name,font=title,fill="#f3f7fa")
        whole.thumbnail((405,210),Image.Resampling.LANCZOS)
        sx,sy=whole.width/v["source_size"][0],whole.height/v["source_size"][1]
        crops=tuple(round(a*(sx if j%2==0 else sy)) for j,a in enumerate(roi))
        ImageDraw.Draw(whole).rectangle(crops,width=2,outline="#ffd15c")
        page.paste(whole,(x,144))
        d.text((x,363),f"測定幅 {width} サンプル",font=label,fill="#c4d2df")
        draw=ImageDraw.Draw(tile)
        w=390 if width==256 else 181
        h=round(tile.height*w/tile.width)
        raw=tile.resize((w,h),Image.Resampling.LANCZOS)
        page.paste(raw,(x,400))
        for (level,y),color in zip(lines.items(),["#21d6e7","#ffd35b","#f26cf2"]):
            draw.line([(j,round(n)) for j,n in enumerate(y)],fill=color)
        overlay=tile.resize((w,h),Image.Resampling.NEAREST)
        page.paste(overlay,(x,567))
        d.text((x,568+h+3),credit,font=small,fill="#b6c5d2")
    page.save(HERE/"photo-contours.jpg",quality=94,subsampling=0)
    (HERE/"photo-profiles.json").write_text(json.dumps(out,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
if __name__=="__main__":
    render()
