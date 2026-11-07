/// 这个类接收 DateTime，产出表示当季番剧区间的字符串。
class AnimeSeason {
  late DateTime _date;
  final _seasons = ['冬季', '春季', '夏季', '秋季'];

  AnimeSeason(DateTime date) {
    _date = date;
  }

  List<int> _getYearAndSeason(DateTime dt) {
    int year = dt.year;
    int month = dt.month;

    int season;
    if ((month == 1) || (month == 2) || (month == 3)) {
      season = 0;
    } else if ((month == 4) || (month == 5) || (month == 6)) {
      season = 1;
    } else if ((month == 7) || (month == 8) || (month == 9)) {
      season = 2;
    } else {
      season = 3;
    }

    return [year, season];
  }

  // 把 DateTime 转成两个字符串（上一季的起止日期），
  // 例如 2024-09-23 -> ['2024-06-01', '2024-09-01']。
  // 为什么要减一季？因为播出日期是番剧开播那天，
  // 通常比「名义上的季节开始」早几天。
  List<String> toSeasonStartAndEnd() {
    var yas = _getYearAndSeason(_date);
    int year = yas[0];
    int season = yas[1];

    var end = DateTime(year, (season + 1) * 3, 1);

    int startMonth = season * 3;
    if (startMonth == 0) {
      startMonth = 12;
      year--;
    }

    var start = DateTime(year, startMonth, 1);
    return [start.toString(), end.toString()];
  }

  @override
  String toString() {
    var yas = _getYearAndSeason(_date);

    return '${yas[0]}年${_seasons[yas[1]]}新番';
  }
}

String getSeasonStringByMonth(int month) {
  if (month <= 3) return '冬';
  if (month <= 6) return '春';
  if (month <= 9) return '夏';
  return '秋';
}

bool isSameSeason(DateTime d1, DateTime d2) {
  return d1.year == d2.year && (d1.month - 1) ~/ 3 == (d2.month - 1) ~/ 3;
}
