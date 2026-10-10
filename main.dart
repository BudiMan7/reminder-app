import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

// Change this if you move to another time zone (WIB = Asia/Jakarta,
// WITA = Asia/Makassar, WIT = Asia/Jayapura).
const String myTimeZone = 'Asia/Makassar';

const List<String> dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

final FlutterLocalNotificationsPlugin plugin = FlutterLocalNotificationsPlugin();

// Needed so the "Turn off" button can work while the app is closed.
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {}

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

class Reminder {
  Reminder({
    required this.id,
    this.title = 'Today',
    this.body = '',
    this.hour = 6,
    this.minute = 0,
    Set<int>? days,
    this.enabled = true,
  }) : days = days ?? {1, 2, 3, 4, 5};

  int id;
  String title;
  String body;
  int hour;
  int minute;
  Set<int> days; // 1 = Monday ... 7 = Sunday
  bool enabled;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'hour': hour,
        'minute': minute,
        'days': days.toList(),
        'enabled': enabled,
      };

  factory Reminder.fromJson(Map<String, dynamic> j) => Reminder(
        id: j['id'] as int,
        title: j['title'] as String,
        body: j['body'] as String,
        hour: j['hour'] as int,
        minute: j['minute'] as int,
        days: Set<int>.from(j['days'] as List),
        enabled: j['enabled'] as bool,
      );
}

class EditResult {
  EditResult({this.delete = false});
  final bool delete;
}

Future<List<Reminder>> loadReminders() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('reminders');
  if (raw == null) return [];
  return (jsonDecode(raw) as List)
      .map((e) => Reminder.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<void> saveReminders(List<Reminder> list) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
      'reminders', jsonEncode(list.map((e) => e.toJson()).toList()));
  await scheduleAll(list);
}

// ---------------------------------------------------------------------------
// Notifications
// ---------------------------------------------------------------------------

NotificationDetails notificationDetails(String body) {
  return NotificationDetails(
    android: AndroidNotificationDetails(
      'daily_reminder',
      'Daily reminders',
      channelDescription: 'Your daily reminder notifications',
      importance: Importance.max,
      priority: Priority.high,
      ongoing: true, // cannot be swiped away (on most phones)
      autoCancel: false, // tapping it does not close it
      styleInformation: BigTextStyleInformation(body),
      actions: const <AndroidNotificationAction>[
        AndroidNotificationAction(
          'turn_off',
          'Turn off',
          cancelNotification: true, // pressing the button closes it
        ),
      ],
    ),
  );
}

tz.TZDateTime nextInstance(int hour, int minute, int weekday) {
  final now = tz.TZDateTime.now(tz.local);
  var t = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
  while (t.weekday != weekday || !t.isAfter(now)) {
    t = t.add(const Duration(days: 1));
  }
  return t;
}

Future<void> scheduleAll(List<Reminder> list) async {
  await plugin.cancelAll();
  for (final r in list) {
    if (!r.enabled) continue;
    for (final day in r.days) {
      await plugin.zonedSchedule(
        r.id * 10 + day, // unique id per reminder + weekday
        r.title,
        r.body,
        nextInstance(r.hour, r.minute, day),
        notificationDetails(r.body),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
      );
    }
  }
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  tzdata.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation(myTimeZone));

  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
  );

  final android = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await android?.requestNotificationsPermission();
  await android?.requestExactAlarmsPermission();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'My Reminders',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Reminder> items = [];

  @override
  void initState() {
    super.initState();
    loadReminders().then((list) => setState(() => items = list));
  }

  Future<void> edit(Reminder? existing) async {
    final isNew = existing == null;
    final draft = existing ??
        Reminder(
          id: items.isEmpty
              ? 1
              : items.map((e) => e.id).reduce((a, b) => a > b ? a : b) + 1,
        );
    final result = await Navigator.push<EditResult>(
      context,
      MaterialPageRoute(
        builder: (_) => EditScreen(reminder: draft, isNew: isNew),
      ),
    );
    if (result == null) return;
    setState(() {
      if (result.delete) {
        items.removeWhere((e) => e.id == draft.id);
      } else if (isNew) {
        items.add(draft);
      }
    });
    await saveReminders(items);
  }

  String timeText(Reminder r) =>
      '${r.hour.toString().padLeft(2, '0')}:${r.minute.toString().padLeft(2, '0')}';

  String daysText(Reminder r) {
    final sorted = r.days.toList()..sort();
    return sorted.map((d) => dayNames[d - 1]).join(', ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Reminders')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => edit(null),
        child: const Icon(Icons.add),
      ),
      body: items.isEmpty
          ? const Center(child: Text('No reminders yet. Tap + to add one.'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final r = items[i];
                return Card(
                  child: ListTile(
                    onTap: () => edit(r),
                    title: Text('${timeText(r)}  ${r.title}'),
                    subtitle: Text(
                      '${daysText(r)}\n${r.body}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    isThreeLine: true,
                    trailing: Switch(
                      value: r.enabled,
                      onChanged: (v) async {
                        setState(() => r.enabled = v);
                        await saveReminders(items);
                      },
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class EditScreen extends StatefulWidget {
  const EditScreen({super.key, required this.reminder, required this.isNew});

  final Reminder reminder;
  final bool isNew;

  @override
  State<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends State<EditScreen> {
  late final TextEditingController titleCtrl;
  late final TextEditingController bodyCtrl;
  late TimeOfDay time;
  late Set<int> days;

  @override
  void initState() {
    super.initState();
    final r = widget.reminder;
    titleCtrl = TextEditingController(text: r.title);
    bodyCtrl = TextEditingController(text: r.body);
    time = TimeOfDay(hour: r.hour, minute: r.minute);
    days = Set.of(r.days);
  }

  @override
  void dispose() {
    titleCtrl.dispose();
    bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> pickTime() async {
    final t = await showTimePicker(context: context, initialTime: time);
    if (t != null) setState(() => time = t);
  }

  void save() {
    final r = widget.reminder;
    r.title = titleCtrl.text;
    r.body = bodyCtrl.text;
    r.hour = time.hour;
    r.minute = time.minute;
    r.days = Set.of(days);
    Navigator.pop(context, EditResult());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'New reminder' : 'Edit reminder'),
        actions: [
          if (!widget.isNew)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () =>
                  Navigator.pop(context, EditResult(delete: true)),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: titleCtrl,
            decoration: const InputDecoration(
              labelText: 'Title',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: bodyCtrl,
            minLines: 4,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: 'Message (write anything)',
              hintText: 'Subjects: Math, English\nWear: white uniform',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.access_time),
            title: Text('Time: ${time.format(context)}'),
            trailing: TextButton(onPressed: pickTime, child: const Text('Change')),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (var d = 1; d <= 7; d++)
                FilterChip(
                  label: Text(dayNames[d - 1]),
                  selected: days.contains(d),
                  onSelected: (v) =>
                      setState(() => v ? days.add(d) : days.remove(d)),
                ),
            ],
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            icon: const Icon(Icons.notifications_active),
            label: const Text('Test notification now'),
            onPressed: () => plugin.show(
              0,
              titleCtrl.text,
              bodyCtrl.text,
              notificationDetails(bodyCtrl.text),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: save, child: const Text('Save')),
        ],
      ),
    );
  }
}
