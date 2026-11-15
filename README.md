# Hots-Spots-Nasa-Challenge

Solution for the **[Harmonization of MODIS and VIIRS Hot Spots](https://www.spaceappschallenge.org/2026/challenges/modis-and-viirs-hot-spots/)** challenge of NASA Space Apps Challenge 2026.
## Objective

Build a **hot spot calendar** from the year 2000 to this day, using both data collections from MODIS and VIIRS. The idea is to harmonize both data from MODIS and VIIRS so that both can be used interchangeably.

There are two parts for this challenge: 

1. **Harmonize data from MODIS and VIIRS.** Bring both satellites to a commong ground, this way we ensure that information from the year 2000 to 2012 wont have any gaps due to the update to de VIIRS satellite. 
2. **Build the website** that allows the user:
   - with a calendar visualize the number of hot spots in a chosen date by the user 

## The challenge with data

Test data: CSV by year in India from FIRMS  in `../datos_crudos/`. This includes MODIS (2000–2025), VIIRS S-NPP (2012–2025) y VIIRS NOAA-20 (2018–2025).

**VIIRS detects between 6 and 8 times more hot spots than MODIS.** For example, if MODIS is used between 2000–2011 and VIIRS from 2012, the map will show 7 times more possible fires that may not exist due to the change in satellite. VIIRS brings a more accurate data since tha radius is smaller and can register smaller wildfires. 

### Attribute Fields for NRT MODIS Active Fire Data

| Attribute | Short Description | Long Description |
| :--- | :--- | :--- |
| `Latitude` | Latitude | Center of 1 km fire pixel, but not necessarily the actual location of the fire as one or more fires can be detected within the 1 km pixel. |
| `Longitude` | Longitude | Center of 1 km fire pixel, but not necessarily the actual location of the fire as one or more fires can be detected within the 1 km pixel. |
| `Brightness` | Brightness temperature 21 (Kelvin) | Channel 21/22 brightness temperature of the fire pixel measured in Kelvin. |
| `Scan` | Along Scan pixel size | The algorithm produces 1 km fire pixels, but MODIS pixels get bigger toward the edge of scan. Scan and track reflect actual pixel size. |
| `Track` | Along Track pixel size | The algorithm produces 1 km fire pixels, but MODIS pixels get bigger toward the edge of scan. Scan and track reflect actual pixel size. |
| `Acq_Date` | Acquisition Date | Date of MODIS acquisition. |
| `Acq_Time` | Acquisition Time | Time of acquisition/overpass of the satellite (in UTC). |
| `Satellite` | Satellite | `A` = Aqua and `T` = Terra. |
| `Confidence` | Confidence (0-100%) | This value is based on a collection of intermediate algorithm quantities used in the detection process. It is intended to help users gauge the quality of individual hotspot/fire pixels. Confidence estimates range between 0 and 100% and are assigned one of the three fire classes (low-confidence fire, nominal-confidence fire, or high-confidence fire). |
| `Version` | Version (Collection and source) | Version identifies the collection (e.g., MODIS Collection 6.1) and source of data processing: Ultra Real-Time (`URT` suffix added to collection), Real-Time (`RT` suffix), Near Real-Time (`NRT` suffix) or Standard Processing (collection only).<br>• `"6.1URT"` - Collection 6.1 Ultra Real-Time processing.<br>• `"6.1RT"` - Collection 6.1 Real-Time processing.<br>• `"6.1NRT"` - Collection 6.1 Near Real-Time processing.<br>• `"6.1"` - Collection 6.1 Standard processing. |
| `Bright_T31` | Brightness temperature 31 (Kelvin) | Channel 31 brightness temperature of the fire pixel measured in Kelvin. |
| `FRP` | Fire Radiative Power (MW - megawatts) | Depicts the pixel-integrated fire radiative power in MW (megawatts). |
| `Type*` | Inferred hot spot type | • `0` = presumed vegetation fire<br>• `1` = active volcano<br>• `2` = other static land source<br>• `3` = offshore |
| `DayNight` | Day or Night | `D` = Daytime fire, `N` = Nighttime fire. |

---

### Attribute Fields for NRT VIIRS 375m Active Fire Data

| Attribute | Short Description | Long Description |
| :--- | :--- | :--- |
| `Latitude` | Latitude | Center of nominal 375 m fire pixel. |
| `Longitude` | Longitude | Center of nominal 375 m fire pixel. |
| `Bright_ti4` / `Brightness` *(in web services)* | Brightness temperature I-4 | VIIRS I-4 channel brightness temperature of the fire pixel measured in Kelvin. |
| `Scan` | Along Scan pixel size | The algorithm produces approximately 375 m pixels at nadir. Scan and track reflect actual pixel size. |
| `Track` | Along Track pixel size | The algorithm produces approximately 375 m pixels at nadir. Scan and track reflect actual pixel size. |
| `Acq_Date` | Acquisition Date | Date of VIIRS acquisition. |
| `Acq_Time` | Acquisition Time | Time of acquisition/overpass of the satellite (in UTC). |
| `Satellite` | Satellite | • `N` = Suomi National Polar-orbiting Partnership (Suomi NPP)<br>• `N20` = NOAA-20 (designated JPSS-1 prior to launch)<br>• `N21` = NOAA-21 (designated JPSS-2 prior to launch) |
| `Confidence` | Confidence | This value is based on a collection of intermediate algorithm quantities used in the detection process. It is intended to help users gauge the quality of individual hotspot/fire pixels. Confidence values are set to `low`, `nominal`, and `high`.<br>• **Low confidence** daytime fire pixels are typically associated with areas of sun glint and lower relative temperature anomaly (<15K) in the mid-infrared channel I4.<br>• **Nominal confidence** pixels are those free of potential sun glint contamination during the day and marked by strong (>15K) temperature anomaly in either day or nighttime data.<br>• **High confidence** fire pixels are associated with day or nighttime saturated pixels.<br><br>*Note: Low confidence nighttime pixels occur only over the geographic area extending from 11° E to 110° W and 7° N to 55° S (South Atlantic Magnetic Anomaly), which can cause spurious brightness temperatures in channel I4 leading to potential false positive alarms. These have been removed from the NRT data distributed by FIRMS.* |
| `Version` | Version (Collection and source) | Version identifies the collection (e.g., VIIRS Collection 1) and source of data processing: Near Real-Time (`NRT` suffix added to collection) or Standard Processing (collection only).<br>• `"1.0NRT"` - Collection 1 NRT processing.<br>• `"1.0"` - Collection 1 Standard processing. |
| `Bright_ti5` / `Brightness_2` *(in web services)* | Brightness temperature I-5 | I-5 Channel brightness temperature of the fire pixel measured in Kelvin. |
| `FRP` | Fire Radiative Power | Depicts the pixel-integrated fire radiative power in MW (megawatts). Given the unique spatial and spectral resolution of the data, the VIIRS 375 m fire detection algorithm was customized and tuned in order to optimize its response over small fires while balancing the occurrence of false alarms. Frequent saturation of the mid-infrared I4 channel (3.55–3.93 µm) driving the detection of active fires requires additional tests and procedures to avoid pixel classification errors. As a result, sub-pixel fire characterization (e.g., FRP retrieval) is only viable across small and/or low-intensity fires. Systematic FRP retrievals are based on a hybrid approach combining 375 and 750 m data (incorporating VIIRS channel M13 [3.973–4.128 µm] 750 m data starting in 2015). |
| `DayNight` | Day or Night | `D` = Daytime fire, `N` = Nighttime fire. |

## Resources

- NASA FIRMS: https://www.earthdata.nasa.gov/data/tools/firms
- API de FIRMS: https://firms.modaps.eosdis.nasa.gov/api/
- Descarga de archivo: https://firms.modaps.eosdis.nasa.gov/download/
- Video del reto (CONAE): https://www.youtube.com/watch?v=tEPHsiZtuvk
