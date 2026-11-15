# 雲の資料調査と密度場の設計

## RockstarのSIGGRAPH 2019講演

Fabian Bauer（Rockstar Games）の講演資料79枚と関連する発表者ノートを確認し、密度場・レイマーチ・照明を更新しました。下表の番号はスライド番号です。[SIGGRAPH公式コースページ](https://advances.realtimerendering.com/s2019/) · [講演のPowerPoint](https://advances.realtimerendering.com/s2019/slides_public_release.pptx)。

| スライド | CirrusEngineへ採用した処理 |
|---|---|
| 14–18 | 512²・RG16Fの雲マップ、1×128・RGBA8の高度LUT、XYとXZの2D変位でずらす1回の3D Perlin–Worley侵食。講演のマスクと高度アトラスに対応するデータを、このエンジンでは手続き生成する。 |
| 19 | 下層の雲マップに合わせて雨霧を置き、雲底からの距離で薄める。 |
| 28–36 | HGの2オクターブと密度に応じた後方散乱の下限。太陽側の二次レイによる光の減衰を天空光にも使う。空の散乱を放物面の方向で評価して並列縮約する。 |
| 35 | 太陽側から積分した透過率で代表遮蔽深度を更新し、指数変換してからミップで濾過する。Highは768²。CirrusEngineは半透明の影を残すために透過率を第1チャンネルに持つ。 |
| 50 | 雲の粗い形状に当たった区間を最大3回二分し、雲の外では大きい歩幅へ戻す。 |

指数シャドウマップの復号はAnnenらの式(3)–(4)を参照しました。RG16Fの指数係数、雲影の半影、散乱の重みと各雲の密度しきい値はCirrusEngineで調整した値です。[Annen et al., Exponential Shadow Maps](https://jankautz.com/publications/esm_gi08.pdf)。

この更新は遠方レイマーチを中心にしています。42–48の近距離フラスタムボクセルと66–72の照度プローブ・反射は未実装です。半解像度の時間再構成は2フレームの既存方式を使い、講演の4フレーム方式は52–56に記載されています。入道雲の形状と渦の速度場は下記の3Dプロファイルと手続き的な配置に基づきます。[実装ガイド](implementation-guide.md)。

## 大型雲の設計履歴

2026-11-05。初版の入道雲は柱状、渦は等間隔のチューブ状に見えたため、以下の一次資料の本文・図を確認して再設計しました。発表の全システムを再現したものではありません。係数、セル配置、回転速度はこのエンジン独自の調整値です。

## 確認した資料

| 一次資料 | 確認した箇所 | この実装への反映 |
|---|---|---|
| Andrew Schneider / Nathan Vos, **Nubis: Authoring Real-Time Volumetric Cloudscapes with the Decima Engine**, SIGGRAPH 2017 — [著者公開PDF](https://d3d3g8mu99pzk9.cloudfront.net/AndrewSchneider/Nubis-Authoring-Realtime-Volumetric-Cloudscapes-with-the-Decima-Engine-Final.pdf) | PDF pp.26–40: coverage、雲種、高度プロファイル、Perlin–Worley、remapによる侵食。pp.46–50: 上部のcoverage変化とanvil。 | `sampleFormationCloud`。被覆率をアルファ倍率にせず、密度のしきい値へ使う。細部も単なる乗算ではなくremapで侵食。上部のcoverageは高度・雲種で変化。 |
| Andrew Schneider, **Nubis, Evolved**, SIGGRAPH 2022 — [公式紹介](https://www.guerrilla-games.com/read/nubis-evolved) / [著者公開PDF](https://d3d3g8mu99pzk9.cloudfront.net/AndrewSchneider/NubisEvolved/NubisEvolved-NoVideos.pdf) | PDF pp.97–105: 高度・境界・密度の制御。pp.139–150: SuperstormのNDF、6つの半径帯の回転速度とskew。p.155: 回転を戻す再投影。 | 雲量・雲頂の制御場と3Dの雲塊ノイズを分離。`vortexRotationFactor`で半径方向に連続な速度差を付ける。`rotateFormationMotion`で同じ速度場を履歴位置の補正へ使用。 |
| Axel Webanck et al., **Procedural Cloudscapes**, Computer Graphics Forum 37(2), Eurographics 2018, DOI [10.1111/cgf.13373](https://doi.org/10.1111/cgf.13373) — [著者公開PDF](https://perso.liris.cnrs.fr/egalin/Articles/2018-cloudscapes.pdf) | §4, PDF pp.3–6: 雲の存在を決める制御関数と形状・細部の分離、compact cubic kernel、寄与の合成。p.11: cyclone/hurricaneへの適用限界。 | 11月5日版の`cloudCellControl`を経て、現在は`cloud_volume.hpp`で高さ・太さの異なる3Dセルを合成し、プロファイルへ焼く。セル自体を不透明な楕円体として描かない。論文のOptimal Transport、経路探索、雲種全体のモデルは実装していない。 |

ページ番号は公開PDFの先頭を1とする番号です。元PDFをリポジトリへ再配布せず、出典へリンクしています。

## 2026-11-08：3Dプロファイルと高詳細化

[Nubis³ (SIGGRAPH 2023) の著者公開PDF](https://d3d3g8mu99pzk9.cloudfront.net/AndrewSchneider/Nubis%20Cubed.pdf)も取得し、PDF pp.71、75、82、84のモデリング・密度の説明とpp.123、125の高詳細化を確認しました。p.75、84、123の図も描画して確認しています。PDFページと紙面のスライド番号は異なります。特にPDF p.84は、ボクセルの3Dプロファイルにもノイズ侵食を適用できること、pp.123、125は密度スケールと侵食後の曲線調整を説明しています。

11月8日版では、C++の階層セルから128³の3Dプロファイルを起動時に生成し、HLSLでノイズによる侵食を行います。64³の周期ベクトル場で滑らかに座標を変形し、Worleyの距離場を直接XYZの変形へ使うことによる尖り・粒状化を避けました。両リソースは全領域で共有し、合計6MiBです。詳しいデータの流れと式は[実装ガイド](implementation-guide.md)にまとめています。

参照元は流体計算で生成した雲を編集・合成して保存しています。本実装の形状は独自の手続き的な階層セルです。流体ソルバー、圧縮SDFによるレイの空間スキップ、発表全体の照明モデルは導入していません。

## 2026-11-05版で修正した問題

### 入道雲

旧版は中心体と上部ドームの距離から直接密度を作り、早い段階で飽和させていました。輪郭が解析形状に支配され、後から弱いノイズを掛けても柱の外観が残りました。2Dの被覆率を高さ方向へ押し出す試作も、平らな頂部・縦壁が残ったため採用していません。

11月5日版は上昇域・側面・頂部を異なる3D制御セルで支えました。compact kernelの和から滑らかなcoverageを作り、Perlin–Worley/Worleyの密度場をそのcoverageでremapします。細部のWorleyは密度を侵食し、丸い塊の輪郭を残します。通常の雲海と入道雲の寄与を加算するため、下部は雲海へ連続します。ノイズの帯域とセル配置は資料からの転記ではなく、実GPU画像で調整したものです。現在の入道雲は上記の3Dプロファイル方式へ更新しています。

### 渦

旧版の `cos(3 * (angle + log(radius) * turns))` による3本の帯を廃止しました。渦に歪めた低周波のcoverage・雲頂分布で雲群を配置し、半径に応じて異なる速度で移流します。速度は6帯の間を連続補間します。中央の目、周囲の高い雲、外縁から通常の雲海への遷移を持ちます。

coverageの強い螺旋変形を3Dノイズへそのまま掛ける試作では、丸い雲塊まで細長く伸びました。そのため、静的なskewは制御場へ掛け、雲塊のノイズは局所的な回転移流だけで動かします。`turns`は帯の本数ではなく、制御場の巻き込み強度です。

### 照明

以前は大型雲を含む全体の最低雲底・最高雲頂で、通常の雲海の照明高度も正規化していました。入道雲の追加だけで背景の天空光配分が変わる問題があります。`cloudDensitySample`は密度に加えて寄与した雲の局所高度を返し、密度で重み付けした高度を照明へ渡します。広い積分用AABBは、照明の高度プロファイルには使いません。自己遮蔽・雲影は引き続き同じ密度関数を積分します。

## 大型雲の画質の限界

- **Nubis Evolvedの完全再現ではありません。** 発表にあるHoudini/Maya由来の流体フィールド、作者のNDFアセット、全ての照明・最適化を導入したものではありません。回転場の強い変形では、丸い塊の保持と厳密なラグランジュ移流を両立する追加の工夫が必要です。
- **Procedural Cloudscapesを台風の実証として扱いません。** 著者はcyclone/hurricaneに対する風表現の解像度不足を記しています。この実装での採用対象は、制御場と密度形状を分ける設計です。渦の回転モデルの参照元はNubis Evolvedです。
- **近距離の写実的な積乱雲には未達です。** 手続き的な形状とノイズでは、成長履歴・浮力・水分・乱流の相関を再現できません。[Nubis³の公式説明](https://www.guerrilla-games.com/read/nubis-cubed)と上記のPDF本文を確認しましたが、その流体アセット・全レンダリングを再現したものではありません。
- 照明と密度の有限サンプリング、単一の代表深度による再投影のため、細い輪郭や互いに重なる雲で近似の影響が残ります。

## 11月5日版の記録と実GPU画像

Releaseビルド後、`scripts/capture-cloud-research.ps1`で固定時刻の画像、フル解像度画像、回転する8秒の連番を保存できます。比較元の実行ファイルは、そのバージョンの `shaders` フォルダーと一緒に保存してください。

```powershell
cmake --build --preset release --parallel
.\scripts\validate.ps1 -SkipBuild
.\scripts\capture-cloud-research.ps1
# 旧版も同時に比較する場合
.\scripts\capture-cloud-research.ps1 -ReferenceExecutable C:\path\to\old\CirrusEngine.exe
```

| 視点 | 変更前 | 変更後 | フル解像度・チェッカーボードOFF |
|---|---|---|---|
| 雲海と入道雲 | [PNG](images/formations-research-before-mixed.png) | [PNG](images/formations-research-mixed.png) | [PNG](images/formations-research-mixed-full.png) |
| 渦の上空 | [PNG](images/formations-research-before-vortex.png) | [PNG](images/formations-research-vortex.png) | [PNG](images/formations-research-vortex-full.png) |

いずれも1600×900 / High / Overcast / 固定60フレーム（1秒）で、エンジンのD3D11出力を保存しています。旧版は `45aaeb5`。入道雲のプリセット半径も3600mから6200mへ変更しているため、密度式だけを変えた比較ではありません。フル解像度列は雲グリッドも1600×900、それ以外の列は800×450の雲グリッド＋半数描画＋時間再構成です。

数値検証と画像差は[検証記録](validation.md)、[JSON](benchmarks/cloud-research.json)に保存しています。画像の差は実装間の差や再構成誤差であり、写実性を点数化する指標ではありません。[夕方の混在シーン](images/formations-research-sunset.png)も別に確認しています。

実装は [`formations.hlsli`](../shaders/formations.hlsli)、[`common.hlsli`](../shaders/common.hlsli)、[`clouds.hlsl`](../shaders/clouds.hlsl) を参照してください。
