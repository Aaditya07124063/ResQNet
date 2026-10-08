export type Step = {
  number: string;
  title: string;
  description: string;
};

// Offline-first order, as implemented (docs/FEATURE_STATUS.md #1–#13).
export const howItWorksSteps: Step[] = [
  {
    number: "01",
    title: "Prepare before anything happens",
    description:
      "Add your trusted contacts and turn on mesh mode. Contacts are cached on your phone so an SOS can reach them without a server. An SOS can also be sent without signing in, over the mesh and by SMS.",
  },
  {
    number: "02",
    title: "Send an SOS, or let detection start one",
    description:
      "Tap SOS, choose a category and confirm during a 5-second countdown. Crash or earthquake detection can also start one after a countdown you can cancel. The SOS is saved on your phone, with GPS if available, before anything is sent.",
  },
  {
    number: "03",
    title: "It goes out every way it can",
    description:
      "Over the mesh to nearby ResQNet phones, which keep a copy and pass it on (store-and-forward). As a pre-filled text to your trusted contacts and local police or disaster numbers, if there's cell signal. And straight to the ResQNet server, if your phone has Internet.",
  },
  {
    number: "04",
    title: "The first phone with Internet uploads it",
    description:
      "The server checks the sending phone's signature, credits the SOS to you rather than the relaying phone, and stores it once even if several phones upload it. Your ResQNet trusted contacts get a generic push notification.",
  },
  {
    number: "05",
    title: "Responders take ownership",
    description:
      "The SOS enters the responder incident queue and moves through acknowledged, assigned, en route, arrived, assisting and resolved. Marking yourself safe or cancelling is recorded, but only a responder closes the incident.",
  },
];

/**
 * Current vs. planned capabilities must never be blurred together. This is
 * the explicit boundary shown on the How It Works page.
 */
export const resilientCommunicationStatus = {
  implemented: [
    "Direct phone-to-phone relay over Bluetooth and Wi-Fi Direct (Google Nearby Connections on Android, MultipeerConnectivity on iOS).",
    "Multi-hop store-and-forward: relays keep other people's SOS alerts and pass them to phones they meet later; the first phone with Internet uploads them. Tested in simulation, A→E.",
    "Signed SOS: relays can't change the text or location; signed hop limits and expiry (24 hours by default); duplicate detection that survives restarts.",
    "Server-side signature verification and de-duplication for relayed SOS alerts.",
    "Responder operations portal (incident queue, workflow, assignment, map, audit log). Built and tested, not yet deployed.",
  ],
  planned: [
    "Physical tests across several real phones, with published range and delivery results.",
    "Ordinary chat over the mesh (today chat messages wait for Internet).",
    "Encryption of mesh payloads (today they are signed, not encrypted).",
    "Connection to verified official disaster-alert feeds (the integration exists; no source is connected yet).",
  ],
};
