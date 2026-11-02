import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

final notifications = FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  try {
    final zone = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(zone.identifier));
  } catch (_) {
    tz.setLocalLocation(tz.getLocation('Africa/Cairo'));
  }

  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  const settings = InitializationSettings(android: android);
  await notifications.initialize(settings);

  final androidPlugin = notifications.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.requestNotificationsPermission();
  await androidPlugin?.requestExactAlarmsPermission();

  runApp(const MonabbihakApp());
}

class Reminder {
  Reminder({
    required this.id,
    required this.title,
    required this.note,
    required this.dateTime,
    required this.enabled,
  });

  final int id;
  String title;
  String note;
  DateTime dateTime;
  bool enabled;

  Map<String, dynamic> toJson() => {
    'id': id, 'title': title, 'note': note,
    'dateTime': dateTime.toIso8601String(), 'enabled': enabled,
  };

  factory Reminder.fromJson(Map<String, dynamic> json) => Reminder(
    id: json['id'] as int,
    title: json['title'] as String,
    note: (json['note'] ?? '') as String,
    dateTime: DateTime.parse(json['dateTime'] as String),
    enabled: json['enabled'] as bool? ?? true,
  );
}

class ReminderStore {
  static const _key = 'reminders_v1';

  Future<List<Reminder>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Reminder.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<Reminder> reminders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(reminders.map((e) => e.toJson()).toList()));
  }
}

class ReminderService {
  static const channel = AndroidNotificationChannel(
    'reminders_channel',
    'التنبيهات',
    description: 'تنبيهات تطبيق منبّهك',
    importance: Importance.max,
  );

  static Future<void> prepare() async {
    final android = notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(channel);
  }

  static Future<void> schedule(Reminder reminder) async {
    if (!reminder.enabled || !reminder.dateTime.isAfter(DateTime.now())) {
      await notifications.cancel(reminder.id);
      return;
    }
    await notifications.zonedSchedule(
      reminder.id,
      reminder.title,
      reminder.note.isEmpty ? 'حان موعد التنبيه' : reminder.note,
      tz.TZDateTime.from(reminder.dateTime, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'reminders_channel',
          'التنبيهات',
          channelDescription: 'تنبيهات تطبيق منبّهك',
          importance: Importance.max,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: reminder.id.toString(),
    );
  }
}

class MonabbihakApp extends StatelessWidget {
  const MonabbihakApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'منبّهك',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF176B5B)),
        scaffoldBackgroundColor: const Color(0xFFF6F8F7),
        fontFamily: 'Roboto',
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final store = ReminderStore();
  List<Reminder> reminders = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    ReminderService.prepare();
  }

  Future<void> _load() async {
    final loaded = await store.load();
    if (!mounted) return;
    setState(() {
      reminders = loaded..sort((a, b) => a.dateTime.compareTo(b.dateTime));
      loading = false;
    });
    for (final reminder in reminders) {
      if (reminder.enabled && reminder.dateTime.isAfter(DateTime.now())) {
        await ReminderService.schedule(reminder);
      }
    }
  }

  Future<void> _persist() async {
    reminders.sort((a, b) => a.dateTime.compareTo(b.dateTime));
    await store.save(reminders);
    if (mounted) setState(() {});
  }

  Future<void> _addOrEdit({Reminder? reminder}) async {
    final result = await showDialog<Reminder>(
      context: context,
      builder: (_) => ReminderDialog(existing: reminder),
    );
    if (result == null) return;
    setState(() {
      final index = reminders.indexWhere((r) => r.id == result.id);
      if (index >= 0) {
        reminders[index] = result;
      } else {
        reminders.add(result);
      }
    });
    await ReminderService.schedule(result);
    await _persist();
  }

  Future<void> _toggle(Reminder reminder, bool value) async {
    reminder.enabled = value;
    if (value) {
      await ReminderService.schedule(reminder);
    } else {
      await notifications.cancel(reminder.id);
    }
    await _persist();
  }

  Future<void> _delete(Reminder reminder) async {
    await notifications.cancel(reminder.id);
    setState(() => reminders.removeWhere((r) => r.id == reminder.id));
    await _persist();
  }

  String _dateLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final date = day == today
        ? 'اليوم'
        : day == today.add(const Duration(days: 1))
            ? 'غداً'
            : '${d.day}/${d.month}/${d.year}';
    final time = TimeOfDay.fromDateTime(d).format(context);
    return '$date • $time';
  }

  @override
  Widget build(BuildContext context) {
    final upcoming = reminders.where((r) => r.dateTime.isAfter(DateTime.now())).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('منبّهك', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEdit(),
        icon: const Icon(Icons.add),
        label: const Text('تنبيه جديد'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 18),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF176B5B), Color(0xFF258B73)],
                    ),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.notifications_active_outlined,
                          color: Colors.white, size: 38),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('رتّب وقتك ولا يفوتك شيء',
                                style: TextStyle(color: Colors.white, fontSize: 16,
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(height: 5),
                            Text('$upcoming تنبيه قادم',
                                style: const TextStyle(color: Colors.white70)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: reminders.isEmpty
                      ? const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.event_note_outlined, size: 64, color: Colors.black26),
                              SizedBox(height: 12),
                              Text('لا توجد تنبيهات حتى الآن',
                                  style: TextStyle(fontSize: 16, color: Colors.black54)),
                              Text('اضغط «تنبيه جديد» لإضافة أول تنبيه',
                                  style: TextStyle(color: Colors.black38)),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
                          itemCount: reminders.length,
                          itemBuilder: (context, index) {
                            final r = reminders[index];
                            final past = !r.dateTime.isAfter(DateTime.now());
                            return Card(
                              elevation: 0,
                              margin: const EdgeInsets.only(bottom: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                                side: BorderSide(color: Colors.grey.shade200),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: const Color(0xFFE4F1ED),
                                    child: Icon(Icons.notifications_none,
                                        color: Theme.of(context).colorScheme.primary),
                                  ),
                                  title: Text(r.title,
                                      style: const TextStyle(fontWeight: FontWeight.bold)),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 5),
                                    child: Text('${_dateLabel(r.dateTime)}${r.note.isEmpty ? '' : '\n${r.note}'}',
                                        maxLines: 3, overflow: TextOverflow.ellipsis),
                                  ),
                                  isThreeLine: r.note.isNotEmpty,
                                  trailing: PopupMenuButton<String>(
                                    onSelected: (v) {
                                      if (v == 'edit') _addOrEdit(reminder: r);
                                      if (v == 'delete') _delete(r);
                                    },
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(value: 'edit', child: Text('تعديل')),
                                      PopupMenuItem(value: 'delete', child: Text('حذف')),
                                    ],
                                  ),
                                  onTap: () => _addOrEdit(reminder: r),
                                  // Use switch as the enabled state control.
                                  // Past reminders remain visible but cannot be scheduled.
                                  dense: false,
                                  // trailing menu is retained; switch is available via long press? 
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

class ReminderDialog extends StatefulWidget {
  const ReminderDialog({super.key, this.existing});
  final Reminder? existing;

  @override
  State<ReminderDialog> createState() => _ReminderDialogState();
}

class _ReminderDialogState extends State<ReminderDialog> {
  final titleController = TextEditingController();
  final noteController = TextEditingController();
  late DateTime selectedDate;
  late TimeOfDay selectedTime;
  bool enabled = true;

  @override
  void initState() {
    super.initState();
    final r = widget.existing;
    titleController.text = r?.title ?? '';
    noteController.text = r?.note ?? '';
    final initial = r?.dateTime ?? DateTime.now().add(const Duration(hours: 1));
    selectedDate = DateTime(initial.year, initial.month, initial.day);
    selectedTime = TimeOfDay.fromDateTime(initial);
    enabled = r?.enabled ?? true;
  }

  @override
  void dispose() {
    titleController.dispose();
    noteController.dispose();
    super.dispose();
  }

  DateTime get combined => DateTime(selectedDate.year, selectedDate.month,
      selectedDate.day, selectedTime.hour, selectedTime.minute);

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: selectedDate.isBefore(DateTime.now())
          ? DateTime.now()
          : selectedDate,
      firstDate: DateTime.now().subtract(const Duration(days: 3650)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      locale: const Locale('ar'),
    );
    if (picked != null) setState(() => selectedDate = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: selectedTime,
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child!,
      ),
    );
    if (picked != null) setState(() => selectedTime = picked);
  }

  void _save() {
    final title = titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اكتب عنوان التنبيه أولاً')),
      );
      return;
    }
    if (!combined.isAfter(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر موعداً في المستقبل')),
      );
      return;
    }
    final r = widget.existing;
    Navigator.pop(
      context,
      Reminder(
        id: r?.id ?? DateTime.now().microsecondsSinceEpoch.remainder(2147483647),
        title: title,
        note: noteController.text.trim(),
        dateTime: combined,
        enabled: enabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'إضافة تنبيه' : 'تعديل التنبيه'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'عنوان التنبيه',
                  hintText: 'مثلاً: موعد اجتماع',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'تفاصيل (اختياري)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.calendar_month),
                      label: Text('${selectedDate.day}/${selectedDate.month}/${selectedDate.year}'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickTime,
                      icon: const Icon(Icons.access_time),
                      label: Text(selectedTime.format(context)),
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('تفعيل التنبيه'),
                value: enabled,
                onChanged: (v) => setState(() => enabled = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }
}
