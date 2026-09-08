import type { LucideIcon } from "lucide-react";
import {
  Siren,
  Users,
  MapPin,
  BellRing,
  Radio,
  ListChecks,
} from "lucide-react";

export type CoreConcept = {
  icon: LucideIcon;
  title: string;
  description: string;
};

/**
 * The six concepts ResQNet is organized around. Kept in one place so the
 * home page and Features page describe the same product the same way.
 */
export const coreConcepts: CoreConcept[] = [
  {
    icon: Siren,
    title: "Emergency SOS",
    description:
      "Trigger an SOS in seconds, whether started manually or by ResQNet's own crash and earthquake detection. Each alert carries a category, a message, and location details so the situation is clear immediately.",
  },
  {
    icon: Users,
    title: "Trusted Contacts",
    description:
      "Build a list of the people who should know when something happens to you. ResQNet notifies them the moment you send an SOS, so you're not the one who has to make that call.",
  },
  {
    icon: MapPin,
    title: "Location",
    description:
      "When location is available, it's attached to your SOS automatically, giving the people coordinating a response a real starting point instead of a guess.",
  },
  {
    icon: BellRing,
    title: "Notifications",
    description:
      "Push notifications keep your trusted contacts and the app itself informed as an SOS is created, acknowledged, or resolved — no need to refresh or ask.",
  },
  {
    icon: Radio,
    title: "Resilient Communication",
    description:
      "ResQNet can relay emergency messages directly between nearby devices over Bluetooth and Wi-Fi Direct, so people close to each other can stay in contact even without a working mobile network.",
  },
  {
    icon: ListChecks,
    title: "Coordination",
    description:
      "Every SOS has a status — open, acknowledged, resolved, or false alarm — so everyone involved can see where things stand instead of wondering if help is already on the way.",
  },
];
