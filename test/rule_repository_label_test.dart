import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/plugin/rule_repository.dart';
import 'package:kazumi/request/config/rules_repository_config.dart';

void main() {
  group('RuleRepository.inferredLabel', () {
    String nameOf(String raw) =>
        RuleRepository(url: RulesRepositoryConfig.baseUri(raw)).displayLabel;

    test('reads the repository name from a raw GitHub URL', () {
      expect(
        nameOf('https://raw.githubusercontent.com/AzlmZ-del/Kazumi-Plus-Rules/main/'),
        'Kazumi-Plus-Rules',
      );
    });

    test('reads the name even when the user pastes index.json', () {
      expect(
        nameOf('https://raw.githubusercontent.com/AzlmZ-del/Kazumi-Plus-Rules/main/index.json'),
        'Kazumi-Plus-Rules',
      );
    });

    test('reads the name from a jsDelivr URL', () {
      expect(
        nameOf('https://cdn.jsdelivr.net/gh/AzlmZ-del/Kazumi-Plus-Rules@main/'),
        'Kazumi-Plus-Rules',
      );
    });

    test('reads the name from a gitcode mirror URL', () {
      expect(
        nameOf('https://raw.gitcode.com/gh_mirrors/ka/KazumiRules/raw/main/'),
        'KazumiRules',
      );
    });

    test('reads the name from a GitLab raw URL', () {
      expect(
        nameOf('https://gitlab.com/owner/rules-repo/-/raw/main/'),
        'rules-repo',
      );
    });

    test('falls back to the last path segment for an unknown host', () {
      expect(nameOf('https://example.com/mirror/rules/'), 'rules');
    });

    test('falls back to the host for a bare origin', () {
      expect(nameOf('https://example.com'), 'example.com');
    });

    test('a configured label still wins', () {
      const repository = RuleRepository(
        url: 'https://raw.githubusercontent.com/AzlmZ-del/Kazumi-Plus-Rules/main/',
        label: '个人仓库',
      );
      expect(repository.displayLabel, '个人仓库');
      expect(repository.inferredLabel, 'Kazumi-Plus-Rules');
    });
  });
}
