import 'package:kazumi/modules/characters/character_item.dart';

/// `/v0/subjects/{0}` 中角色字段的响应。
/// 内含 [CharacterItem] 列表，用于展示番剧角色概况。
class CharactersResponse {
  final List<CharacterItem> charactersList;

  CharactersResponse({
    required this.charactersList,
  });

  factory CharactersResponse.fromJson(List list) {
    List<CharacterItem> resCharactersList =
        list.map((i) => CharacterItem.fromJson(i)).toList();
    return CharactersResponse(
      charactersList: resCharactersList,
    );
  }

  factory CharactersResponse.fromTemplate() {
    return CharactersResponse(
      charactersList: [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'charactersList': charactersList.map((e) => e.toJson()).toList(),
    };
  }
}
