import 'package:echo_app/src/providers/featured_group_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FeaturedGroup.fromJson', () {
    test('parses a full payload', () {
      final g = FeaturedGroup.fromJson(const {
        'id': 'g-1',
        'title': 'Echo Public Group',
        'description': 'Say hi',
        'icon_url': '/api/groups/g-1/avatar',
        'member_count': 4,
        'is_member': false,
      });

      expect(g.id, 'g-1');
      expect(g.title, 'Echo Public Group');
      expect(g.description, 'Say hi');
      expect(g.iconUrl, '/api/groups/g-1/avatar');
      expect(g.memberCount, 4);
      expect(g.isMember, false);
    });

    test('tolerates missing optional fields', () {
      final g = FeaturedGroup.fromJson(const {'id': 'g-2', 'title': 'Bare'});

      expect(g.id, 'g-2');
      expect(g.description, isNull);
      expect(g.iconUrl, isNull);
      expect(g.memberCount, 0);
      expect(g.isMember, false);
    });

    test('coerces a numeric member_count from a num', () {
      final g = FeaturedGroup.fromJson(const {
        'id': 'g-3',
        'title': 'Counted',
        'member_count': 12.0,
      });
      expect(g.memberCount, 12);
    });
  });
}
