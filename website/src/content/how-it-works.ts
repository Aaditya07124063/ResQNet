export type Step = {
  number: string;
  title: string;
  description: string;
};

export const howItWorksSteps: Step[] = [
  {
    number: "01",
    title: "Set up your trusted contacts",
    description:
      "Add the people you'd want to know first — family, roommates, coworkers. ResQNet keeps this list on your device and syncs it to your account.",
  },
  {
    number: "02",
    title: "Trigger an SOS",
    description:
      "Start an SOS yourself from the app, or let ResQNet's crash or earthquake detection start one for you when it recognizes a strong signal of an emergency.",
  },
  {
    number: "03",
    title: "ResQNet records and distributes it",
    description:
      "The alert — its category, message, and location if available — is recorded by ResQNet's backend, which then notifies your trusted contacts and, where you're connected, other nearby ResQNet users.",
  },
  {
    number: "04",
    title: "Everyone can see where things stand",
    description:
      "Your trusted contacts see what happened and where. You and anyone coordinating the response can track the SOS as it moves from open to acknowledged to resolved.",
  },
];

/**
 * Section 4 of the build spec: current vs. planned capabilities must
 * never be blurred together. This is the explicit boundary referenced by
 * the How It Works page's resilient-communication explanation.
 */
export const resilientCommunicationStatus = {
  implemented: [
    "Direct device-to-device message relay over Bluetooth and Wi-Fi Direct, for devices that are physically nearby and have ResQNet's mesh mode active.",
    "Local crash detection and earthquake detection that can trigger an SOS without the person needing to open the app first.",
  ],
  planned: [
    "Wide-area mesh relay across multiple hops, beyond direct nearby-device range.",
    "Coordination with official emergency-response or government systems.",
  ],
};
