# Hots-Spots-Nasa-Challenge

Solution for the **[Harmonization of MODIS and VIIRS Hot Spots](https://www.spaceappschallenge.org/2026/challenges/modis-and-viirs-hot-spots/)** challenge of NASA Space Apps Challenge 2026.
## Objective

Build a **hot spot calendar** from the year 2000 to this day, using both data collections from MODIS and VIIRS. The idea is to harmonize both data from MODIS and VIIRS so that both can be used interchangeably.

There are two parts for this challenge: 

1. **Harmonize data from MODIS and VIIRS.** Bring both satellites to a commong ground, this way we ensure that information from the year 2000 to 2012 wont have any gaps due to the update to de VIIRS satellite. 
2. **Build the website** that allows the user:
   - with a calendar visualize the number of hot spots in a chosen date by the user 

## The challenge wit data

Test data: CSV by year in India from FIRMS  in `../datos_crudos/`. This includes MODIS (2000–2025), VIIRS S-NPP (2012–2025) y VIIRS NOAA-20 (2018–2025).

**VIIRS detects between 6 and 8 times more hot spots than MODIS.** For example, if MODIS is used between 2000–2011 and VIIRS from 2012, the map will show 7 times more possible fires that may not exist due to the change in satellite. VIIRS brings a more accurate data since tha radius is smaller and can register smaller wildfires. 

## Resources

- NASA FIRMS: https://www.earthdata.nasa.gov/data/tools/firms
- API de FIRMS: https://firms.modaps.eosdis.nasa.gov/api/
- Descarga de archivo: https://firms.modaps.eosdis.nasa.gov/download/
- Video del reto (CONAE): https://www.youtube.com/watch?v=tEPHsiZtuvk
