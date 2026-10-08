import type { LucideIcon } from "lucide-react";
import {
  Siren,
  Users,
  MapPin,
  Radio,
  TriangleAlert,
  Activity,
} from "lucide-react";

export type CoreConcept = {
  icon: LucideIcon;
  title: string;
  description: string;
};

/**
 * The homepage capability summary. Every line maps to an implemented
 * feature in docs/FEATURE_STATUS.md; physical-test caveats are kept.
 */
export const coreConcepts: CoreConcept[] = [
  {
    icon: Siren,
    title: "Emergency SOS",
    description:
      "One tap, a category (medical, fire, flood, earthquake, trapped, rescue or general), and a 5-second countdown you can cancel. The SOS is saved on your phone before anything is sent, so it survives a failed attempt.",
  },
  {
    icon: Radio,
    title: "Offline mesh relay",
    description:
      "Nearby phones exchange the SOS over Bluetooth and Wi-Fi Direct, keep a copy, and pass it on to phones they meet later, up to a signed hop limit. Tested in simulation; multi-phone field tests are still to come.",
  },
  {
    icon: MapPin,
    title: "Location sharing",
    description:
      "Your GPS position and its accuracy travel with the SOS when the phone has a fix, so people looking for you have a starting point instead of a description.",
  },
  {
    icon: Users,
    title: "Trusted contacts",
    description:
      "The people who should know first. ResQNet opens a pre-filled text to them and local police or disaster numbers (needs cell signal), and the server sends a push notification to those who use ResQNet.",
  },
  {
    icon: TriangleAlert,
    title: "Hazard awareness",
    description:
      "Flood, fire, landslide and blocked-road reports spread between nearby phones. Official alerts stay labeled \"official\" only if their server signature verifies; everything else shows as a community report.",
  },
  {
    icon: Activity,
    title: "Automatic detection",
    description:
      "On-device crash and earthquake detection can start an SOS for you after a countdown. They still need field testing, so treat them as a backup, not a guarantee.",
  },
];
