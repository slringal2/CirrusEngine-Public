# 雲の先端の形が、1本の視線の色になるまで

横から見た雲の先を直すときは、まず密度を参照する3次元の場所を追い、その後で、その場所から何色の光がカメラへ届くかを追う。この順に読むと、輪郭・陰・ちらつきのどれを直しているのか見分けやすい。 [雲の共通関数](../../shaders/common.hlsli) · [実写と描画の比較](../sky-study/README.md)

## 1．風で曲がる位置を決める

`unmixedCloudShape` はワールド座標 `p` から積算移動量 `Wind.xy` を引いて、風と一緒に動く雲の座標を求める。`bendConvectiveTop` では、強い対流と風があるとき、雲層下部を支点にして、高くなるほど風上へずらした位置の密度を読む。たとえば、変更後の位置 x=110 m から風上の x=100 m の雲を読むと、元の房は画面で10 m風下に現れる。実装では二次元の風向と高度ごとの重みでずれを決め、肩を局所的に回転する。 [座標の逆変換と風下の雲頂](../../shaders/common.hlsli)

## 2．厚い房とほどけた先を作る

Classicの `thermalCoreWeight` は、局所的な柱の厚み・被覆率・雲底からの高さ・対流の強さを掛ける。次は実際の補強式で、`envelope` は細部を削る前の大きな形、`coreWeight` はこの位置の補強量である。 [密度の実装](../../shaders/common.hlsli)

```hlsl
return lerp(envelope, 1, coreWeight * smoothstep(0.15, 0.53, envelope));
```

例えば `envelope = 0.40`、`coreWeight = 0.30` なら結果は約0.53になる。空の点（0.00）は0.00のままなので、上空全部が白くなるのを防げる。早期終了に使う `upperEnvelope` にもこの関数を適用する。細かくサンプリングすれば見える房が、粗い判定で捨てられるのを防ぐためである。

`backgroundCloudShape` は薄くなる風下側の肩を選び、外気との混合で下がる密度と、上流の雲体から運ばれる少量の密度を合わせる。Cumulus は独自の内部補強を持つため、Classicの補強式は適用しない。輪郭の外側と内側を透過率画像で読むと、光の当たり方を変えずにどこが薄くなったかを確認できる。 [密度と透過率の図解](../sky-study/shape-change.md)

## 3．雲の中で光を積算する

`CloudCS` から `traceCloudRay` に入ると、視線上の距離 `t` ごとに密度を評価する。照明が必要な点では、`lightOpticalDepth` または条件を満たした遮蔽キャッシュから太陽側の光学的厚さを取り、`shadeCloud` に渡す。以下は `accumulateCloudSample` の色に関わる部分。 [視線と光の積分](../../shaders/clouds.hlsl)

```hlsl
float weight = accumulated.transmittance * (1 - attenuation);
accumulated.radiance += weight * lighting;
// この後ろにある物体から、カメラへ届く光の割合を更新する。
accumulated.transmittance *= attenuation;
```

区間の透過率は `attenuation = exp(-extinction * ds)`。手前までの透過率が0.8、次の区間が0.5なら、その区間からの光の重みは0.4、後続区間へ残る透過率も0.4。手前の雲を厚くすると、同じ場所の背後にある山も暗くなる。近景は `LightNearCloudCS` と `IntegrateNearCloudCS` で視錐台格子を照明・積分する。最後に `near.rgb + near.a * far.rgb` の順で重ねる。 [近景と遠景の合成](../../shaders/scene.hlsl)

## 4．ちらつきを直す場所を選ぶ

`TemporalCS` はチェッカーボードで直接計算しなかった画素を再構成する。`CloudAntialiasCS` は雲色と透過率をさらに安定化する。後者の `reprojectCloudAA` は代表距離から3D位置を作り、前の風とカメラを考慮して過去の画面座標に戻す。過去に地形が手前だった画素や雲の距離が合わない画素を除き、残りの履歴を現在の近傍の色域に収める。山や草の輪郭だけがぶれる場合は、地表の最終フィルタ `ResolveEdgesPS` も別に確認できる。 [雲の再構成](../../shaders/clouds.hlsl) · [雲の専用TAA](../../shaders/cloud_antialias.hlsl) · [最終画面の縁フィルタ](../../shaders/scene.hlsl)
