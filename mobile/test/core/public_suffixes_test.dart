import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/public_suffixes.dart';

void main() {
  final list = PublicSuffixList.parse(File(publicSuffixListAsset).readAsStringSync());

  // publicsuffix.org's own test cases (tests/test_psl.txt), for the rules they name
  test('reads the list as publicsuffix.org checks it', () {
    final cases = <String, String?>{
      'com': null,
      'example.com': 'example.com',
      'b.example.com': 'example.com',
      'a.b.example.com': 'example.com',
      'uk.com': null,
      'example.uk.com': 'example.uk.com',
      'b.example.uk.com': 'example.uk.com',
      'test.ac': 'test.ac',
      'jp': null,
      'test.jp': 'test.jp',
      'www.test.jp': 'test.jp',
      'ac.jp': null,
      'test.ac.jp': 'test.ac.jp',
      'c.kobe.jp': null,
      'b.c.kobe.jp': 'b.c.kobe.jp',
      'a.b.c.kobe.jp': 'b.c.kobe.jp',
      'city.kobe.jp': 'city.kobe.jp',
      'www.city.kobe.jp': 'city.kobe.jp',
      'ck': null,
      'test.ck': null,
      'b.test.ck': 'b.test.ck',
      'www.ck': 'www.ck',
      'www.www.ck': 'www.ck',
      'us': null,
      'test.us': 'test.us',
      'ak.us': null,
      'test.ak.us': 'test.ak.us',
      'k12.ak.us': null,
      'test.k12.ak.us': 'test.k12.ak.us',
      // 食狮.com.cn, 食狮.公司.cn, 公司.cn
      'xn--85x722f.com.cn': 'xn--85x722f.com.cn',
      'xn--85x722f.xn--55qx5d.cn': 'xn--85x722f.xn--55qx5d.cn',
      'www.xn--85x722f.xn--55qx5d.cn': 'xn--85x722f.xn--55qx5d.cn',
      'xn--55qx5d.cn': null,
    };
    cases.forEach((host, expected) => expect(list.registrableDomain(host), expected, reason: host));
  });

  test('keeps sites under a suffix anyone can open a site under apart', () {
    expect(list.registrableDomain('alice.herokuapp.com'), 'alice.herokuapp.com');
    expect(list.registrableDomain('user.github.io'), 'user.github.io');
    expect(list.registrableDomain('www.user.github.io'), 'user.github.io');
    expect(list.publicSuffix('user.github.io'), 'github.io');
  });

  test('is read whatever the line endings', () {
    final crlf = PublicSuffixList.parse('// comment\r\ncom\r\n*.ck\r\n!www.ck\r\n');
    expect(crlf.registrableDomain('a.example.com'), 'example.com');
    expect(crlf.registrableDomain('www.ck'), 'www.ck');
  });
}
