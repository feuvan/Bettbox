import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'app_localizations.dart';
import 'print.dart';

extension StringExtension on String {
  bool get isHttpUrl {
    return RegExp(r'^(http|https)://', caseSensitive: false).hasMatch(this);
  }

  bool get isFileUrl {
    return RegExp(r'^file://', caseSensitive: false).hasMatch(this);
  }

  bool get isRemoteUrl {
    return isHttpUrl;
  }

  bool get isLocalUrl {
    return isFileUrl;
  }

  bool get isUrl {
    return isRemoteUrl || isLocalUrl;
  }

  dynamic get splitByMultipleSeparators {
    final parts = split(
      RegExp(r'[, ;]+'),
    ).where((part) => part.isNotEmpty).toList();

    return parts.length > 1 ? parts : this;
  }

  int compareToLower(String other) {
    return toLowerCase().compareTo(other.toLowerCase());
  }

  List<int> get encodeUtf16LeWithBom {
    final byteData = ByteData(length * 2);
    final bom = [0xFF, 0xFE];
    for (int i = 0; i < length; i++) {
      int charCode = codeUnitAt(i);
      byteData.setUint16(i * 2, charCode, Endian.little);
    }
    return bom + byteData.buffer.asUint8List();
  }

  Uint8List? get getBase64 {
    final regExp = RegExp(r'base64,(.*)');
    final match = regExp.firstMatch(this);
    final realValue = match?.group(1) ?? '';
    if (realValue.isEmpty) {
      return null;
    }
    try {
      return base64.decode(realValue);
    } catch (e) {
      return null;
    }
  }

  bool get isSvg {
    return endsWith('.svg');
  }

  /// Whether this looks like an HTML document, such as the sign-in page a
  /// captive portal returns instead of the subscription's config.
  bool get isHtmlDocument {
    final sample = length > 4096 ? substring(0, 4096) : this;
    final head = (sample.startsWith('\uFEFF') ? sample.substring(1) : sample)
        .trimLeft()
        .toLowerCase();
    if (head.startsWith('<!doctype html') || head.startsWith('<html')) {
      return true;
    }
    return head.contains('</html>') || head.contains('</body>');
  }

  bool get isRegex {
    try {
      RegExp(this);
      return true;
    } catch (e) {
      commonPrint.debug(e.toString());
      return false;
    }
  }

  String toMd5() {
    final bytes = utf8.encode(this);
    return md5.convert(bytes).toString();
  }
}

extension StringExtensionSafe on String? {
  String getSafeValue(String defaultValue) {
    return this?.isEmpty != false ? defaultValue : this!;
  }
}

/// Thrown when a subscription returns a web page (a captive portal or sign-in
/// page) instead of a configuration file.
class ProfileContentNotConfigException implements Exception {
  const ProfileContentNotConfigException();

  @override
  String toString() => 'Profile content is a web page, not a config file';
}

final _yamlParseErrorRegExp = RegExp(r'yaml: line \d+:');

extension ObjectExtension on Object {
  String get formatError => _format(isLog: false);

  String get formatErrorLog => _format(isLog: true);

  String _format({required bool isLog}) {
    final errorStr = toString();
    if (this is ProfileContentNotConfigException) {
      return isLog ? errorStr : appLocalizations.profileContentNotConfig;
    }
    if (_yamlParseErrorRegExp.hasMatch(errorStr)) {
      return isLog
          ? errorStr
          : '${appLocalizations.profileParseErrorDesc}: $errorStr';
    }
    if (errorStr.contains('DioException [bad response]') ||
        errorStr.contains('status code of')) {
      final match = RegExp(r'status code of (\d+)').firstMatch(errorStr);
      final statusCode = match?.group(1);
      if (statusCode != null) {
        return isLog
            ? 'Failed to import profile. Please check your network status or try resetting the subscription link ( HTTP error code: $statusCode )'
            : appLocalizations.profileImportFailed(statusCode);
      }
    }
    return errorStr;
  }
}
