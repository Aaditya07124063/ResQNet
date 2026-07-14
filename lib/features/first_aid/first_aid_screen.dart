import 'package:flutter/material.dart';

class FirstAidTopic {
  final String title;
  final IconData icon;
  final Color color;
  final List<String> steps;
  final String? warning;

  const FirstAidTopic({
    required this.title,
    required this.icon,
    required this.color,
    required this.steps,
    this.warning,
  });
}

const List<FirstAidTopic> _topics = [
  FirstAidTopic(
    title: 'CPR (Adult)',
    icon: Icons.favorite,
    color: Colors.red,
    warning: 'Call 108/112 first if possible. Only perform if person is unresponsive and not breathing.',
    steps: [
      'Check response: tap shoulders, shout "Are you okay?"',
      'Place person on their back on a firm surface',
      'Place heel of one hand on center of chest, other hand on top, interlock fingers',
      'Push hard and fast: 5-6 cm deep, 100-120 compressions per minute (beat of "Staying Alive")',
      'After 30 compressions, give 2 rescue breaths: tilt head back, lift chin, pinch nose, seal mouth, blow for 1 second',
      'Continue 30:2 cycles without stopping until help arrives or person breathes',
    ],
  ),
  FirstAidTopic(
    title: 'Severe Bleeding',
    icon: Icons.bloodtype,
    color: Colors.red,
    steps: [
      'Apply firm, direct pressure on the wound with clean cloth or bandage',
      'Do NOT remove the cloth if soaked — add more layers on top',
      'Raise the injured limb above heart level if no fracture suspected',
      'If bleeding is from arm/leg and won\'t stop: tie a belt/cloth 5 cm above the wound tightly (tourniquet), note the time',
      'Keep the person warm and lying down',
      'Get to a hospital immediately',
    ],
  ),
  FirstAidTopic(
    title: 'Snake Bite',
    icon: Icons.pest_control,
    color: Colors.green,
    warning: 'DO NOT cut the wound, suck venom, apply ice, or tie a tight tourniquet. These make it worse.',
    steps: [
      'Move the person away from the snake. Try to remember its color/pattern (photo only if safe)',
      'Keep the person CALM and STILL — movement spreads venom faster',
      'Remove rings, watches, tight clothing near the bite before swelling starts',
      'Immobilize the bitten limb with a splint, keep it BELOW heart level',
      'Mark the edge of swelling with a pen every 15 minutes',
      'Carry the person (do not let them walk) to the nearest hospital with antivenom',
      'India: government district hospitals stock polyvalent antivenom for the "Big 4" (cobra, krait, Russell\'s viper, saw-scaled viper)',
    ],
  ),
  FirstAidTopic(
    title: 'Burns',
    icon: Icons.local_fire_department,
    color: Colors.orange,
    warning: 'Do NOT apply toothpaste, butter, oil, or ice — these damage tissue further.',
    steps: [
      'Remove person from heat source',
      'Cool the burn under cool RUNNING water for 20 minutes (not ice water)',
      'Remove jewelry/tight items near the burn before swelling',
      'Cover loosely with clean cling film or a sterile non-fluffy cloth',
      'Do not burst blisters',
      'For burns larger than the person\'s palm, on face/hands/joints, or deep burns — go to hospital immediately',
    ],
  ),
  FirstAidTopic(
    title: 'Choking (Adult)',
    icon: Icons.airline_seat_flat,
    color: Colors.purple,
    steps: [
      'Ask "Are you choking?" — if they can cough or speak, encourage coughing',
      'If they cannot breathe/speak: give 5 sharp back blows between shoulder blades with heel of hand',
      'If still choking: stand behind, wrap arms around waist, make a fist above navel',
      'Give 5 quick inward-and-upward abdominal thrusts (Heimlich)',
      'Alternate 5 back blows and 5 thrusts until object comes out',
      'If person becomes unconscious, start CPR',
    ],
  ),
  FirstAidTopic(
    title: 'Fracture / Broken Bone',
    icon: Icons.personal_injury,
    color: Colors.blueGrey,
    steps: [
      'Do not move the injured area — support it in the position found',
      'Immobilize with a splint: tie a stick/rolled newspaper alongside the limb with cloth strips',
      'Splint should cover the joint above AND below the break',
      'Apply a cold pack wrapped in cloth to reduce swelling',
      'For neck/back injuries: do NOT move the person at all unless in immediate danger',
      'Transport to hospital keeping the limb still',
    ],
  ),
  FirstAidTopic(
    title: 'Heatstroke',
    icon: Icons.thermostat,
    color: Colors.deepOrange,
    warning: 'Heatstroke (hot dry skin, confusion, temp >40°C) is life-threatening. Act fast.',
    steps: [
      'Move person to shade or a cool room immediately',
      'Remove excess clothing',
      'Cool aggressively: wet their skin with water and fan them; put cold packs on neck, armpits, groin',
      'If conscious, give small sips of water or ORS — never force fluids if drowsy',
      'Lay them on their side if vomiting or unconscious',
      'Get to hospital — organ damage happens within an hour',
    ],
  ),
  FirstAidTopic(
    title: 'Drowning',
    icon: Icons.pool,
    color: Colors.blue,
    steps: [
      'Get the person out of water only if safe for you — reach with a stick/rope rather than swimming',
      'Check breathing — if not breathing, start CPR immediately (start with 5 rescue breaths)',
      'Do NOT waste time trying to drain water from lungs',
      'If breathing, place in recovery position (on side)',
      'Keep them warm — remove wet clothes, cover with blanket',
      'Everyone rescued from drowning needs hospital check — lungs can fail hours later',
    ],
  ),
  FirstAidTopic(
    title: 'Electric Shock',
    icon: Icons.electric_bolt,
    color: Colors.amber,
    warning: 'Do NOT touch the person until power is off — you will be shocked too.',
    steps: [
      'Turn off the power source / main switch',
      'If you can\'t, push person away using DRY wood, plastic, or rubber — never metal or anything wet',
      'Check breathing — start CPR if needed',
      'Treat visible burns with cool running water',
      'Even if they seem fine, go to hospital — internal injuries and heart rhythm problems are invisible',
    ],
  ),
  FirstAidTopic(
    title: 'Seizure / Fits',
    icon: Icons.psychology,
    color: Colors.indigo,
    warning: 'Do NOT put anything in their mouth or hold them down.',
    steps: [
      'Clear hard/sharp objects away from the person',
      'Cushion their head with something soft',
      'Time the seizure',
      'After shaking stops, roll them onto their side (recovery position)',
      'Stay with them until fully alert',
      'Call for help if: seizure lasts over 5 minutes, repeats, person is injured, pregnant, or it\'s their first seizure',
    ],
  ),
  FirstAidTopic(
    title: 'Heart Attack',
    icon: Icons.monitor_heart,
    color: Colors.red,
    steps: [
      'Signs: chest pain/pressure, pain spreading to arm/jaw/back, sweating, breathlessness, nausea',
      'Call 108/112 immediately — do not wait to see if it passes',
      'Have the person sit down, resting against a wall, knees bent',
      'Loosen tight clothing',
      'If available and not allergic: chew one aspirin (325mg) slowly',
      'If they become unresponsive and stop breathing, start CPR',
    ],
  ),
];

class FirstAidScreen extends StatefulWidget {
  const FirstAidScreen({super.key});

  @override
  State<FirstAidScreen> createState() => _FirstAidScreenState();
}

class _FirstAidScreenState extends State<FirstAidScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = _topics
        .where((t) => t.title.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('First Aid Guide — Offline')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Search: bleeding, snake, CPR...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: filtered.length,
              itemBuilder: (_, i) {
                final t = filtered[i];
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: t.color.withOpacity(0.15),
                      child: Icon(t.icon, color: t.color),
                    ),
                    title: Text(t.title,
                        style:
                            const TextStyle(fontWeight: FontWeight.bold)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => _TopicDetail(topic: t)),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TopicDetail extends StatelessWidget {
  final FirstAidTopic topic;
  const _TopicDetail({required this.topic});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(topic.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (topic.warning != null)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning, color: Colors.red),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(topic.warning!,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600))),
                ],
              ),
            ),
          ...topic.steps.asMap().entries.map(
                (e) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: topic.color,
                        child: Text('${e.key + 1}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Text(e.value,
                              style: const TextStyle(
                                  fontSize: 15, height: 1.35))),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}