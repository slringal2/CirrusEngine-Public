# World textures and terrain

The textures in this directory are adapted from [Poly Haven assets distributed under CC0 1.0](https://polyhaven.com/license). The fern and needle textures combine diffuse and alpha maps. The terrain and bark images were resized for the runtime package. The grass blade image stores the brightness variation across four source blades.

| Files | Source |
| --- | --- |
| fir-needles.png | [Fir Tree 01](https://polyhaven.com/a/fir_tree_01) |
| blade-grain.png | [Grass Medium 02](https://polyhaven.com/a/grass_medium_02) |
| fern-fronds.png | [Fern 02](https://polyhaven.com/a/fern_02) |
| bark.jpg, bark-normal.jpg | [Bark Brown 02](https://polyhaven.com/a/bark_brown_02) |
| meadow.jpg | [Leafy Grass](https://polyhaven.com/a/leafy_grass) |
| soil.jpg, soil-normal.jpg | [Forest Ground 04](https://polyhaven.com/a/forest_ground_04) |
| gravel.jpg, gravel-normal.jpg | [River Small Rocks](https://polyhaven.com/a/river_small_rocks) |
| ridge.jpg, ridge-normal.jpg | [Rocky Terrain](https://polyhaven.com/a/rocky_terrain) |

The ridge elevation comes from the public-domain [USGS 3DEP Bare Earth DEM](https://www.usgs.gov/3d-elevation-program/about-3dep-products-services). The [export service](https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer/exportImage) was queried for the Teton Range in Wyoming, with WGS84 bounds −110.969, 43.645, −110.665, 43.861 and output CRS EPSG:32612. The 769 × 769 export was turned to face west, resampled to 513 × 513, and reduced to positive relief above 2,075 metres at 57 percent of the source height. `teton-relief.r16` stores the resulting relief at 24 counts per metre as row-major unsigned little-endian samples. The engine scales and blends the terrain into its own valley.
