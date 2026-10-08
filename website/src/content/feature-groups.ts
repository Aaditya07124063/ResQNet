import type { LucideIcon } from "lucide-react";
import {
  Siren,
  Radio,
  MapPin,
  Users,
  TriangleAlert,
  Activity,
  ListChecks,
  ShieldCheck,
} from "lucide-react";

export type FeatureGroup = {
  icon: LucideIcon;
  title: string;
  /** What it does and when it helps. */
  summary: string;
  /** Honest maturity, from docs/FEATURE_STATUS.md. */
  status: string;
  points: string[];
};

export const featureGroups: FeatureGroup[] = [
  {
    icon: Siren,
    title: "Emergency SOS",
    summary: "The fastest way to say \"I need help\", designed to work even when nothing else does.",
    status: "Working in automated tests",
    points: [
      "One tap, a category (medical, fire, flood, earthquake, trapped, rescue or general) and an optional message, then a 5-second countdown with Send now and Cancel.",
      "Saved on your phone before any transport is tried, so a failed send isn't lost.",
      "Can be sent without signing in, over the mesh and by SMS.",
      "Cancel or mark yourself safe at any time; nearby phones get a signed cancellation notice.",
    ],
  },
  {
    icon: Radio,
    title: "Offline mesh",
    summary: "Phone-to-phone relay for when towers or the Internet are down.",
    status: "Tested in simulation; needs real-device field tests",
    points: [
      "Nearby phones connect directly over Bluetooth and Wi-Fi Direct, with no Internet or cell network between them.",
      "Store-and-forward: a phone that receives an SOS keeps it and passes it to phones it meets later, until one with Internet uploads it.",
      "Signed hop limit and expiry (24 hours by default), with duplicate detection that survives app restarts.",
      "Relays can't alter the text or location: phones reject an SOS that doesn't match its signature.",
      "\"I am safe\" broadcasts to ResQNet phones around you.",
      "Range is not fixed and is not claimed. On iOS the mesh works only while the app is open.",
    ],
  },
  {
    icon: MapPin,
    title: "Location sharing",
    summary: "A starting point for anyone trying to reach you.",
    status: "Needs real-device GPS testing",
    points: [
      "Your GPS position and its accuracy are attached to an SOS when the phone has a fix.",
      "You can share your location in a chat message.",
      "Optional: let the server use your last location to alert you about emergencies nearby (deleted after 30 days without updates).",
      "Exact SOS location is visible to phones that receive the SOS over the mesh, and to authorized responders; other staff see it rounded to about 1 km.",
    ],
  },
  {
    icon: Users,
    title: "Trusted contacts and notifications",
    summary: "The people who should know first, ready before you need them.",
    status: "SMS and push need production verification",
    points: [
      "Add contacts with a name, phone number and relationship; they're cached on your phone for offline use.",
      "On SOS, the app opens a pre-filled text to your trusted contacts and local police or disaster numbers. It needs cell signal, and you send it.",
      "Contacts who use ResQNet get a push notification with your name, the category and your location, but never your message.",
      "Groups for family or teams, built from your trusted contacts.",
    ],
  },
  {
    icon: TriangleAlert,
    title: "Disaster awareness",
    summary: "Local hazard information that also spreads without the Internet.",
    status: "Partial; no official feed connected yet",
    points: [
      "Report hazards such as floods, fires, landslides, fallen power lines or blocked roads; reports spread between nearby phones.",
      "Official alerts keep their \"official\" label only if the server's signature verifies; anything else is shown as a community report.",
      "Emergency map with hazards, safe zones and SOS markers.",
      "Local emergency numbers for the country you're in, where included in the app.",
      "The integration for official disaster feeds exists; no source is connected yet.",
    ],
  },
  {
    icon: Activity,
    title: "Automatic emergency detection",
    summary: "A backup for moments when you can't reach your phone.",
    status: "Needs field testing",
    points: [
      "Crash detection and earthquake detection run on the phone and can start an SOS after a countdown you can cancel.",
      "Earthquake readings can be cross-checked against public USGS and EMSC feeds; server-side corroboration across phones is built but not yet deployed.",
      "Detector scores are not validated probabilities: expect missed events and false alarms until field testing is done.",
    ],
  },
  {
    icon: ListChecks,
    title: "Responder operations",
    summary: "An operations portal for the people who answer the SOS.",
    status: "Built and tested; not yet deployed",
    points: [
      "Incident queue with an enforced workflow: reported, acknowledged, assigned, en route, arrived, assisting, resolved, or stood down with a reason.",
      "Assignment and reassignment, an incident timeline, map, alerts and disaster-source management.",
      "Separate permissions to monitor, respond and assign; every staff action is audit-logged.",
      "See For Responders for details.",
    ],
  },
  {
    icon: ShieldCheck,
    title: "Privacy controls and data retention",
    summary: "Clear limits on who sees what, and for how long.",
    status: "Implemented; retention schedule is configured per deployment",
    points: [
      "Medical details (blood group, allergies) go into an automatic SOS only if you opt in. The setting is off by default and resets on sign-out.",
      "Mesh SOS payloads are signed, not encrypted.",
      "Personal SOS data (message, exact location) stops being served 90 days after a responder closes the incident and is then redacted; the link to your account is removed after 730 days. Backups can hold copies for up to about 8 weeks longer.",
      "Profile photo visibility: private, contacts only or public.",
      "See Safety & Privacy for the full picture, including limitations.",
    ],
  },
];
