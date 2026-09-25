import 'package:flutter_test/flutter_test.dart';
import 'package:laya_command_bar_example/src/commands.dart';
import 'package:laya_command_bar_example/src/intents.dart';
import 'package:laya_command_bar_example/src/slots.dart';

void main() {
  test('parseTime reads clock times, named times and durations', () {
    String? label(String s) => parseTime(s)?.label;
    expect(label('remind me to call mom at 7'), '7:00');
    expect(label('take my pills at 9pm'), '9:00 PM');
    expect(label('wake me up at 6:30'), '6:30');
    expect(label('alert me when it is 5pm'), '5:00 PM');
    expect(label('lunch on Friday noon'), '12:00 PM');
    expect(label('set a timer for 10 minutes'), 'in 10 min');
    expect(parseTime('set a timer for 10 minutes')!.isDuration, isTrue);
    expect(label('parking meter in an hour'), 'in 1 h');
    expect(label('timer 5 min'), 'in 5 min');
    expect(label('15% of 240'), isNull);
    expect(label('buy 2 eggs'), isNull);
    expect(label('meeting at 25'), isNull);
  });

  test('parseDay reads relative days, weekdays and dates', () {
    expect(parseDay('meeting with Alex tomorrow at 3pm'), 'Tomorrow');
    expect(parseDay('dentist next Tuesday'), 'Next Tue');
    expect(parseDay('meeting with Bo friday'), 'Fri');
    expect(parseDay('team offsite June 12 to 14'), 'Jun 12');
    expect(parseDay('rent on the 1st'), 'Day 1');
    expect(parseDay('buy milk'), isNull);
  });

  test('parsePerson reads recipients, relations and names after with', () {
    expect(parsePerson('text sam I am here'), 'Sam');
    expect(parsePerson('text John I am running late'), 'John');
    expect(parsePerson('email the landlord about the heater'), 'the landlord');
    expect(parsePerson('send dad a happy birthday message'), 'Dad');
    expect(parsePerson('reply to Kim: sounds good'), 'Kim');
    expect(parsePerson('meeting with Bo friday'), 'Bo');
    expect(parsePerson('lunch with mom on Friday'), 'Mom');
    expect(parsePerson('remind me to call mom at 7'), 'Mom');
    expect(parsePerson('coffee with milk'), isNull);
    expect(parsePerson('buy milk'), isNull);
  });

  test('messageBody is the text after the recipient', () {
    expect(messageBody('text sam I am here'), 'I am here');
    expect(
      messageBody('tell Maria that the report is ready'),
      'the report is ready',
    );
    expect(messageBody('reply to Kim: sounds good'), 'sounds good');
    expect(messageBody('text sam'), isNull);
  });

  test('evaluate does arithmetic, percentages and conversions', () {
    String? label(String s) => evaluate(s)?.label;
    expect(label('what is 12 * 9'), '108');
    expect(label('3.5 * 18 + 7'), '70');
    expect(label('(2 + 3) x 4'), '20');
    expect(label('2 ^ 10'), '1024');
    expect(label('-3 + 1'), '-2');
    expect(label('15% of 240'), '36');
    expect(label('convert 5 miles to km'), '8.0467 km');
    expect(label('100 c to f'), '212 °F');
    expect(label('1 / 0'), isNull);
    expect(label('what is 12'), isNull);
    expect(label('what is 12 *'), isNull);
    expect(label('5 miles to kg'), isNull);
    expect(label('why is the sky blue'), isNull);
  });

  test('parseSetting reads the setting and the direction', () {
    expect(parseSetting('turn on dark mode'), (
      setting: AppSetting.darkMode,
      on: true,
    ));
    expect(parseSetting('switch to light mode'), (
      setting: AppSetting.darkMode,
      on: false,
    ));
    expect(parseSetting('make the font bigger'), (
      setting: AppSetting.largeText,
      on: true,
    ));
    expect(parseSetting('make the text smaller'), (
      setting: AppSetting.largeText,
      on: false,
    ));
    expect(parseSetting('disable notifications'), (
      setting: AppSetting.notifications,
      on: false,
    ));
    expect(parseSetting('turn off sounds'), (
      setting: AppSetting.sounds,
      on: false,
    ));
    expect(parseSetting('unmute'), (setting: AppSetting.sounds, on: true));
    expect(parseSetting('change language to Spanish'), isNull);
  });

  test('stripWhen removes times and days', () {
    expect(stripWhen('call mom at 7'), 'call mom');
    expect(stripWhen('meeting with Alex tomorrow at 3pm'), 'meeting with Alex');
    expect(
      stripWhen('dentist appointment next Tuesday'),
      'dentist appointment',
    );
    expect(stripWhen('lunch with mom on Friday noon'), 'lunch with mom');
    expect(stripWhen('buy 2 eggs'), 'buy 2 eggs');
  });

  test('activityFor describes each command', () {
    Activity? run(CommandIntent i, String text) =>
        activityFor(i, text, CommandSlots.parse(text));
    final reminder = run(CommandIntent.reminder, 'remind me to call mom at 7')!;
    expect((reminder.title, reminder.detail), ('Call mom', '7:00'));
    final event = run(
      CommandIntent.event,
      'schedule dentist appointment next Tuesday',
    )!;
    expect((event.title, event.detail), ('Dentist appointment', 'Next Tue'));
    final message = run(CommandIntent.message, 'text sam I am here')!;
    expect((message.title, message.detail), ('To Sam', 'I am here'));
    final task = run(
      CommandIntent.task,
      'add to my list: renew car insurance',
    )!;
    expect(task.title, 'Renew car insurance');
    expect(run(CommandIntent.calculate, 'what is 12 * 9')!.detail, '= 108');
    expect(run(CommandIntent.calculate, 'why is the sky blue'), isNull);
    expect(
      run(CommandIntent.settings, 'turn on dark mode')!.detail,
      'Turned on',
    );
    expect(run(CommandIntent.settings, 'change language to Spanish'), isNull);
  });
}
