import type { LucideIcon } from "lucide-react";
import {
  Siren,
  Users,
  MapPin,
  BellRing,
  Radio,
  ShieldCheck,
} from "lucide-react";

export type FeatureGroup = {
  icon: LucideIcon;
  title: string;
  summary: string;
  points: string[];
};

export const featureGroups: FeatureGroup[] = [
  {
    icon: Siren,
    title: "Emergency SOS",
    summary:
      "A fast, clear way to signal that something is wrong — started by you or recognized automatically.",
    points: [
      "Trigger an SOS manually in a few taps, with a category (medical, fire, flood, earthquake, trapped, rescue, or general) and an optional message.",
      "Automatic SOS from ResQNet's on-device crash detection and earthquake detection, so a person who can't reach their phone isn't left without an alert.",
      "Every SOS is tracked through a clear status: open, acknowledged, resolved, or false alarm.",
      "A full history of your past SOS events stays available in the app.",
    ],
  },
  {
    icon: Users,
    title: "Trusted Contacts",
    summary:
      "The people who should know first, kept ready before an emergency happens.",
    points: [
      "Add contacts with a name, phone number, and relationship, stored against your account.",
      "Trusted contacts are notified when you send an SOS.",
      "Manage your list any time — add, edit, or remove contacts as your circumstances change.",
    ],
  },
  {
    icon: MapPin,
    title: "Location",
    summary: "Emergency location information, included when it's available.",
    points: [
      "When your device can provide a location, it's attached to your SOS automatically.",
      "Location accuracy is recorded alongside the coordinates, so responders know how much to rely on it.",
      "Location is only ever collected as part of an emergency event — not tracked continuously in the background.",
    ],
  },
  {
    icon: BellRing,
    title: "Notifications",
    summary:
      "Push notifications that keep the right people informed without extra effort.",
    points: [
      "Trusted contacts and other affected users are notified through push notifications when an SOS is created.",
      "Status changes — acknowledged, resolved, false alarm — are reflected back to your own connected devices in real time.",
      "Notification delivery is handled by ResQNet's backend, not a third-party dashboard you have to check separately.",
    ],
  },
  {
    icon: Radio,
    title: "Resilient Communication",
    summary:
      "Built-in device-to-device relay for when a mobile network isn't available.",
    points: [
      "ResQNet can discover and connect to nearby devices directly, using Bluetooth and Wi-Fi Direct, without needing an internet connection between them.",
      "Emergency messages can be relayed between nearby devices that are part of the same mesh, extending an alert's reach on the ground.",
      "This is a real, implemented capability limited to devices in physical proximity — not a substitute for wide-area connectivity. See How It Works for the current vs. planned scope.",
    ],
  },
  {
    icon: ShieldCheck,
    title: "Security",
    summary:
      "An emergency app has to protect emergency information — not just move fast.",
    points: [
      "Every account action goes through an authenticated backend session — there is no unauthenticated write access to your data.",
      "Access to your data is scoped to your own account; the backend is built so one user's request can never read or modify another user's records.",
      "Profile photo visibility is controlled by you (private, contacts only, or public).",
      "See Safety & Privacy for the full picture of how ResQNet handles emergency data.",
    ],
  },
];
