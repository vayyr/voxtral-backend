import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'main.dart'; // To navigate to TranscriptionScreen
import 'models.dart';
import 'storage.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final StorageService _storage = StorageService();
  List<SessionMeta> _recentSessions = [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _loadSessions();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadSessions() async {
    final sessions = await _storage.listSessions();
    if (mounted) {
      setState(() {
        _recentSessions = sessions.take(5).toList();
      });
    }
  }

  void _openSession(String? sessionId) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => TranscriptionScreen(initialSessionId: sessionId),
          ),
        )
        .then((_) => _loadSessions()); // Reload when coming back
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final timeString = DateFormat('HH:mm').format(now);
    final dateString = DateFormat('EEEE, MMMM d').format(now);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              // Time & Date
              Text(
                timeString,
                style: const TextStyle(
                  fontSize: 80,
                  fontWeight: FontWeight.w200,
                  color: Colors.white,
                  height: 1.0,
                  letterSpacing: -2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                dateString.toUpperCase(),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.4),
                  letterSpacing: 2,
                ),
              ),

              const SizedBox(height: 60),

              // Day Progress Widget
              const Text(
                'DAY PROGRESS (07:00 - 23:00)',
                style: TextStyle(
                  fontSize: 10,
                  color: Color(0xFFD4A574),
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 20),
              DayProgressWidget(now: now),

              const SizedBox(height: 60),

              // Start / Recent
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'RECENT SESSIONS',
                    style: TextStyle(
                      fontSize: 10,
                      color: Color(0xFFD4A574),
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => _openSession(null),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.2),
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.add, color: Colors.white, size: 14),
                          SizedBox(width: 4),
                          Text(
                            'NEW SESSION',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                              letterSpacing: 1.0,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              Expanded(
                child: ListView.separated(
                  itemCount: _recentSessions.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final session = _recentSessions[index];
                    return GestureDetector(
                      onTap: () => _openSession(session.id),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.05),
                          ),
                        ),
                        child: Row(
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  session.displayName,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${session.cardCount} cards · ${DateFormat('MMM d, HH:mm').format(session.createdAt)}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.white.withValues(alpha: 0.4),
                                  ),
                                ),
                              ],
                            ),
                            const Spacer(),
                            Icon(
                              Icons.arrow_forward_ios,
                              size: 14,
                              color: Colors.white.withValues(alpha: 0.2),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DayProgressWidget extends StatelessWidget {
  final DateTime now;

  const DayProgressWidget({super.key, required this.now});

  @override
  Widget build(BuildContext context) {
    // 7 AM to 11 PM = 16 hours = 960 minutes
    const startHour = 7;
    const endHour = 23;
    const totalMinutes = (endHour - startHour) * 60;

    final currentMinutes = (now.hour * 60 + now.minute) - (startHour * 60);
    double progress = currentMinutes / totalMinutes;

    // Clamp progress
    progress = progress.clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return SizedBox(
          height: 30, // Height for the ticks and labels
          width: width,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.centerLeft,
            children: [
              // Background Line
              Container(
                height: 2,
                width: width,
                color: Colors.white.withValues(alpha: 0.1),
              ),

              // Active Line
              Container(
                height: 2,
                width: width * progress,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFFD4A574), Colors.white],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                ),
              ),

              // Current Time Indicator Dot
              Positioned(
                left: (width * progress) - 4, // Center the dot
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white,
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
              ),

              // Start Label
              const Positioned(
                left: 0,
                bottom: -20,
                child: Text(
                  '07:00',
                  style: TextStyle(color: Colors.grey, fontSize: 10),
                ),
              ),

              // End Label
              const Positioned(
                right: 0,
                bottom: -20,
                child: Text(
                  '23:00',
                  style: TextStyle(color: Colors.grey, fontSize: 10),
                ),
              ),

              // Percentage Label (optional, currently disabled for minimal look)
            ],
          ),
        );
      },
    );
  }
}
