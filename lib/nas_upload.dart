import 'dart:io';

import 'core_bridge.dart';
import 'download_merge.dart';
import 'local_store.dart';
import 'models.dart';
import 'webdav_client.dart';

class NasUploadResult {
  const NasUploadResult({
    required this.uploaded,
    required this.existing,
    required this.skipped,
    required this.failures,
  });

  final int uploaded;
  final int existing;
  final int skipped;
  final Map<String, String> failures;

  bool get ok => failures.isEmpty;
}

String nasFolder(Drama drama) => safeFileName(drama.title);

String nasSeasonFolder(Drama drama) => '${nasFolder(drama)}/Season 01';

String nasPosterPath(Drama drama) => '${nasFolder(drama)}/poster.jpg';

String nasNfoPath(Drama drama) => '${nasFolder(drama)}/tvshow.nfo';

String nasRelativePath(Drama drama, int number) {
  final title = nasFolder(drama);
  final episode = '$number'.padLeft(2, '0');
  return '$title/Season 01/S01E$episode.mp4';
}

String nasShowNfo(
  Drama drama, {
  int episodes = 0,
  int bytes = 0,
  String source = '',
}) {
  final buffer = StringBuffer('<?xml version="1.0" encoding="utf-8"?>\n');
  buffer.writeln('<tvshow>');
  buffer.writeln('  <title>${_escape(drama.title)}</title>');
  final plot = drama.description.trim();
  if (plot.isNotEmpty) buffer.writeln('  <plot>${_escape(plot)}</plot>');
  final genre = drama.category.trim();
  if (genre.isNotEmpty) buffer.writeln('  <genre>${_escape(genre)}</genre>');
  final year = _year(drama.onlineDate);
  if (year > 0) buffer.writeln('  <year>$year</year>');
  final score = drama.score.trim();
  if (score.isNotEmpty) buffer.writeln('  <rating>${_escape(score)}</rating>');
  if (episodes > 0) buffer.writeln('  <episodecount>$episodes</episodecount>');
  if (bytes > 0) buffer.writeln('  <size>${_size(bytes)}</size>');
  if (source.isNotEmpty) buffer.writeln('  <source>${_escape(source)}</source>');
  for (final tag in drama.tags.take(10)) {
    final value = tag.trim();
    if (value.isNotEmpty) buffer.writeln('  <tag>${_escape(value)}</tag>');
  }
  buffer.writeln('</tvshow>');
  return buffer.toString();
}

String _size(int bytes) {
  if (bytes < 1 << 20) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1 << 30) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
}

String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

int _year(String onlineDate) {
  final match = RegExp(r'(?:19|20)\d{2}').firstMatch(onlineDate);
  return int.tryParse(match?.group(0) ?? '') ?? 0;
}

WebDavClient? nasClient(LocalStore store) {
  if (!store.nasConfigured) return null;
  return WebDavClient(
    baseUrl: store.nasUrl,
    username: store.nasUser,
    password: store.nasPassword,
    root: store.nasRoot,
  );
}

Future<NasUploadResult> uploadToNas(
  AppRepository repository,
  LocalStore store,
  List<DownloadJob> jobs, {
  void Function(int done, int total, String label)? onProgress,
}) async {
  final client = nasClient(store);
  if (client == null) throw WebDavException('请先在设置中配置 NAS 地址');
  var uploaded = 0;
  var existing = 0;
  var skipped = 0;
  final failures = <String, String>{};

  final groups = <String, List<DownloadJob>>{};
  for (final job in jobs) {
    groups.putIfAbsent(job.drama.id, () => <DownloadJob>[]).add(job);
  }

  var done = 0;
  for (final group in groups.values) {
    final drama = group.first.drama;
    try {
      await client.ensureDirectory(nasSeasonFolder(drama));
    } catch (error) {
      for (final job in group) {
        failures['${drama.title} 第 ${job.episode.number} 集'] = '$error';
      }
      done += group.length;
      onProgress?.call(done, jobs.length, drama.title);
      continue;
    }

    try {
      final poster = nasPosterPath(drama);
      if (!await client.exists(poster)) {
        final path = await repository.cover(drama);
        final file = File(path);
        if (await file.exists()) await client.uploadFile(poster, file);
      }
    } catch (_) {}

    try {
      final episodes = group.length;
      final bytes = group.fold<int>(0, (sum, job) => sum + job.bytes);
      final source = SourceSite.byId(drama.source).name;
      await client.uploadText(
        nasNfoPath(drama),
        nasShowNfo(
          drama,
          episodes: episodes,
          bytes: bytes,
          source: source,
        ),
      );
    } catch (_) {}

    for (final job in group) {
      final label = '${drama.title} 第 ${job.episode.number} 集';
      onProgress?.call(done, jobs.length, label);
      done++;
      try {
        if (job.state != 'completed') {
          skipped++;
          continue;
        }
        final relative = nasRelativePath(drama, job.episode.number);
        if (await client.exists(relative)) {
          existing++;
          continue;
        }
        final plan = await repository.localPlayback(drama, job.episode);
        if (plan == null || !plan.local) {
          skipped++;
          continue;
        }
        final file = File(plan.url);
        if (!await file.exists()) {
          skipped++;
          continue;
        }
        await client.uploadFile(relative, file);
        uploaded++;
      } catch (error) {
        failures[label] = '$error';
      }
    }
  }
  onProgress?.call(jobs.length, jobs.length, '');
  return NasUploadResult(
    uploaded: uploaded,
    existing: existing,
    skipped: skipped,
    failures: failures,
  );
}
