/**
 * Typed shape for the situational-awareness map on the homepage.
 *
 * This mirrors the real app's data model on purpose — `type` matches the
 * hazard categories in `lib/core/services/hazard_service.dart`'s `Hazard`
 * class (flood, fire, landslide, powerline, road_blocked, other), and the
 * "where does this come from" split below matches
 * `lib/core/services/government_alert_feed_service.dart`'s own doc
 * comment: a single, already-built integration point (`feedUrl`) that is
 * currently an empty placeholder, not a connected feed.
 *
 * Today, on-device, ResQNet does two genuinely real things with hazard
 * data:
 *  - peers relay hazard reports they create directly to each other over
 *    the mesh (Bluetooth/Wi-Fi Direct), with no server involved;
 *  - `EarthquakeFeedService` polls USGS's and EMSC's real public
 *    earthquake feeds as a cross-check against local sensor-based
 *    detection (never as the trigger itself).
 *
 * Neither of those is "a live hazard map of Nepal and India" — that would
 * require a connected authority feed, which does not exist yet. The array
 * below is illustrative example data, sized and located to make the map
 * readable, not a claim about real current conditions anywhere.
 */
export type HazardType = "flood" | "landslide" | "seismic";

export type HazardSeverity = "low" | "moderate" | "high";

export type HazardRegion = "nepal" | "india";

export type Hazard = {
  id: string;
  type: HazardType;
  region: HazardRegion;
  label: string;
  coordinates: [number, number]; // [lat, lng]
  severity: HazardSeverity;
};

/**
 * Illustrative only — see the module doc comment above. Coordinates are
 * real places (so the map reads as genuinely geographic), the hazards
 * assigned to them are not.
 */
export const demoHazards: Hazard[] = [
  { id: "np-1", type: "flood", region: "nepal", label: "Koshi River basin", coordinates: [26.5, 87.15], severity: "moderate" },
  { id: "np-2", type: "landslide", region: "nepal", label: "Mid-hills, central Nepal", coordinates: [27.9, 84.9], severity: "high" },
  { id: "np-3", type: "seismic", region: "nepal", label: "Kathmandu Valley", coordinates: [27.7172, 85.324], severity: "moderate" },
  { id: "in-1", type: "flood", region: "india", label: "Brahmaputra basin, Assam", coordinates: [26.2, 92.9], severity: "high" },
  { id: "in-2", type: "landslide", region: "india", label: "Western Ghats, Kerala", coordinates: [10.1, 76.7], severity: "moderate" },
  { id: "in-3", type: "seismic", region: "india", label: "Himalayan foothills, Uttarakhand", coordinates: [30.3, 78.0], severity: "low" },
  { id: "in-4", type: "flood", region: "india", label: "Gangetic plains, Bihar", coordinates: [25.6, 85.1], severity: "moderate" },
];

export const hazardTypeMeta: Record<HazardType, { label: string; color: string }> = {
  // Colors match the real app's own Hazard.color mapping, not an
  // invented palette — see hazard_service.dart.
  flood: { label: "Flood", color: "#3b82f6" },
  landslide: { label: "Landslide", color: "#b45309" },
  seismic: { label: "Seismic", color: "#dc2626" },
};

export const regionMeta: Record<HazardRegion, { label: string; center: [number, number] }> = {
  nepal: { label: "Nepal", center: [28.3949, 84.124] },
  india: { label: "India", center: [22.5937, 78.9629] },
};
