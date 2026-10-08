/**
 * Documentary photographs used on the site. Every entry is a real
 * photograph from Wikimedia Commons with a verified license — see
 * website/IMAGE_SOURCES.md for the full source/license registry.
 *
 * The pictured people are not ResQNet users and ResQNet played no part in
 * these events; captions say where and when each photo was taken so the
 * imagery reads as context for the problem, never as a product claim.
 *
 * Files live in public/photos/<id>-<width>.webp (resized and re-encoded
 * from the originals; no other edits).
 */

export type PhotoId = keyof typeof photos;

export type PhotoEntry = {
  width: number;
  height: number;
  /** Generated widths available in public/photos. */
  widths: readonly number[];
  alt: string;
  /** Where/when — shown as a small caption next to the photo. */
  place: string;
  credit: string;
  license: string;
  licenseUrl?: string;
  sourceUrl: string;
};

export const photos = {
  "nepal-earthquake-rescue-2015": {
    width: 5760,
    height: 3840,
    widths: [640, 1080, 1600, 2400],
    alt: "A search-and-rescue worker in an orange uniform walks with a search dog past a collapsed brick house after the April 2015 earthquake in Nepal.",
    place: "Nepal, April 2015 earthquake",
    credit: "Hilmi Hacaloğlu / VOA",
    license: "Public domain",
    sourceUrl: "https://commons.wikimedia.org/wiki/File:2015_Nepal_depremi_(8).jpg",
  },
  "chennai-flood-rooftop-2015": {
    width: 5184,
    height: 3456,
    widths: [640, 1080, 1600, 2400],
    alt: "Aerial view of brown floodwater covering Chennai, with a group of people waiting on a rooftop, photographed from an Indian Air Force helicopter in December 2015.",
    place: "Chennai, India, December 2015 floods",
    credit: "Indian Air Force",
    license: "GODL-India",
    licenseUrl: "https://data.gov.in/sites/default/files/Gazette_Notification_OGDL.pdf",
    sourceUrl:
      "https://commons.wikimedia.org/wiki/File:2015_South_Indian_flood_Chennai_by_Indian_Air_Force_helicopters.jpg",
  },
  "bihar-kosi-flood-boat-2008": {
    width: 2592,
    height: 1944,
    widths: [640, 1080, 1600, 2400],
    alt: "During the 2008 Kosi floods in Bihar, people wade through floodwater carrying children and belongings to a rescue boat.",
    place: "Kosi floods, Bihar, India, August 2008",
    credit: "Kumarrakajee",
    license: "CC BY-SA 3.0",
    licenseUrl: "https://creativecommons.org/licenses/by-sa/3.0/",
    sourceUrl: "https://commons.wikimedia.org/wiki/File:NDRF_in_Bihar_Flood_2.jpg",
  },
  "nepal-earthquake-rubble-2015": {
    width: 5760,
    height: 3840,
    widths: [640, 1080, 1600, 2400],
    alt: "",
    place: "Nepal, April 2015 earthquake",
    credit: "Hilmi Hacaloğlu / VOA",
    license: "Public domain",
    sourceUrl: "https://commons.wikimedia.org/wiki/File:2015_Nepal_depremi_(7).jpg",
  },
  "ndrf-nepal-search-rescue-2015": {
    width: 2200,
    height: 1650,
    widths: [640, 1080, 1600],
    alt: "Rescuers from India's National Disaster Response Force, in orange uniforms and yellow helmets, carry a person on a stretcher across rubble in Nepal after the 2015 earthquake.",
    place: "Nepal, 2015 earthquake",
    credit: "Ministry of Home Affairs, Government of India (PIB)",
    license: "GODL-India",
    licenseUrl: "https://data.gov.in/sites/default/files/Gazette_Notification_OGDL.pdf",
    sourceUrl:
      "https://commons.wikimedia.org/wiki/File:The_NDRF_personnel_engaged_in_Search_and_Rescue_Operations_in_the_earthquake_hit_Nepal_(1).jpg",
  },
  "nepal-broken-trail-2015": {
    width: 2464,
    height: 3200,
    widths: [640, 1080, 1600],
    alt: "A trekker with a backpack climbs a mountain trail buried under landslide rock and soil in Nepal, the day after the April 2015 earthquake.",
    place: "Trail between Surke and Paiya, Nepal, 26 April 2015",
    credit: "Goutam1962",
    license: "CC BY-SA 4.0",
    licenseUrl: "https://creativecommons.org/licenses/by-sa/4.0/",
    sourceUrl:
      "https://commons.wikimedia.org/wiki/File:Broken_Trail_between_Surke_and_Paiya_after_Earthquake.jpg",
  },
  "ernakulam-flood-2018": {
    width: 2304,
    height: 4096,
    widths: [640, 1080, 1600],
    alt: "People wade through deep floodwater at the Ernakulam bus stand in Kerala during the August 2018 floods, with buses standing in the water.",
    place: "Ernakulam, Kerala, India, August 2018 floods",
    credit: "Ranjithkssp",
    license: "CC BY-SA 3.0",
    licenseUrl: "https://creativecommons.org/licenses/by-sa/3.0/",
    sourceUrl: "https://commons.wikimedia.org/wiki/File:Flood_Pict.jpg",
  },
  "machhapuchhre-ghandruk": {
    width: 4288,
    height: 2848,
    widths: [640, 1080, 1600, 2400],
    alt: "The peak of Machhapuchhre catching the last evening light above clouds and dark forested hills, seen from Ghandruk village in Nepal.",
    place: "Machhapuchhre from Ghandruk, Nepal",
    credit: "Nischal Tiwari",
    license: "CC BY-SA 3.0",
    licenseUrl: "https://creativecommons.org/licenses/by-sa/3.0/",
    sourceUrl: "https://commons.wikimedia.org/wiki/File:Machhapuchhre_-_The_Fish_Tail_Mountain.JPG",
  },
} satisfies Record<string, PhotoEntry>;
