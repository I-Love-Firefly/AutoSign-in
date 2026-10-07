import 'dart:async';

import 'package:flutter/material.dart';

import 'domain.dart';
import 'timetable.dart';

class TimetablePage extends StatefulWidget {
  final Account account;
  final TimetableController controller;
  final DateTime Function() clock;
  const TimetablePage({
    super.key,
    required this.account,
    required this.controller,
    required this.clock,
  });
  @override
  State<TimetablePage> createState() => _TimetablePageState();
}

class _TimetablePageState extends State<TimetablePage> {
  late final Timer timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final id = widget.controller.id(widget.account);
      final table = widget.controller.schedules[id];
      final error =
          widget.controller.errors[id] ?? widget.controller.storageError;
      final status = widget.controller.statuses[id];
      final current = table?.current(widget.clock()) ?? [];
      final updated = table == null ? null : malaysiaTime(table.fetchedAt);
      return Scaffold(
        appBar: AppBar(
          title: Text('课表 · ${widget.account.name}'),
          actions: [
            IconButton(
              tooltip: '刷新课表',
              onPressed: widget.controller.running
                  ? null
                  : () => widget.controller.refresh(widget.account),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              widget.account.campusId,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (status != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(status),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(error, style: const TextStyle(color: Colors.red)),
              ),
            if (table == null && status == null)
              Text(
                widget.account.acPassword.isEmpty
                    ? '请在编辑账号中填写AC系统密码，再读取课表。'
                    : '尚未获取课表，请点击右上角刷新。',
              ),
            if (table != null) ...[
              const SizedBox(height: 12),
              Text(
                '学期：${table.semester.substring(0, 4)}/${table.semester.substring(4)}',
              ),
              Text(
                '更新时间：${updated!.year}/${updated.month}/${updated.day} ${minuteLabel(updated.hour * 60 + updated.minute)}',
              ),
              Text(
                table.teachingWeek(widget.clock()) == null
                    ? '本学期教学周起点尚未核对，暂不显示“上课中”。'
                    : '按学校本科校历判断教学周，马来西亚时间 UTC+8。',
              ),
              const SizedBox(height: 12),
              Text(
                '课表仅提醒上课安排，签到是否开放仍由签到系统确认。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (table.lessons.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: Text('当前学期没有课程。'),
                ),
              for (var day = 1; day <= 7; day++)
                if (table.lessons.any((l) => l.weekday == day)) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 20, bottom: 8),
                    child: Text(
                      weekdays[day - 1],
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  for (final lesson in table.lessons.where(
                    (l) => l.weekday == day,
                  ))
                    Card(
                      color: current.contains(lesson)
                          ? const Color(0xFFFFF3CD)
                          : null,
                      child: ListTile(
                        title: Text(
                          '${current.contains(lesson) ? '上课中 · ' : ''}${lesson.name}',
                        ),
                        subtitle: Text(
                          '${lesson.code} · ${lesson.time}\n地点：${lesson.venue}\n教学周：${lesson.weeks.join(', ')}',
                        ),
                      ),
                    ),
                ],
            ],
          ],
        ),
      );
    },
  );
}
