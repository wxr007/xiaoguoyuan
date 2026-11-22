import 'dart:io';

import 'core_bridge.dart';
import 'download_merge.dart';
import 'local_store.dart';
import 'models.dart';
import 'webdav_client.dart';

class NasUploadResult {
  const NasUploadResult({
    required this.uploaded,
    required this.skipped,
    required this.failures,
  });

  final int uploaded;
  final int skipped;
  final Map<String, String> failures;

  bool get ok => failures.isEmpty;
}

String nasRelativePath(Drama drama, int number) {
  final title = safeFileName(drama.title);
  final episode = '$number'.padLeft(2, '0');
  return '$title/Season 01/$title - S01E$episode.mp4';
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
  var skipped = 0;
  final failures = <String, String>{};
  for (var index = 0; index < jobs.length; index++) {
    final job = jobs[index];
    final label = '${job.drama.title} 第 ${job.episode.number} 集';
    onProgress?.call(index, jobs.length, label);
    try {
      if (job.state != 'completed') {
        skipped++;
        continue;
      }
      final plan = await repository.localPlayback(job.drama, job.episode);
      if (plan == null || !plan.local) {
        skipped++;
        continue;
      }
      final file = File(plan.url);
      if (!await file.exists()) {
        skipped++;
        continue;
      }
      final relative = nasRelativePath(job.drama, job.episode.number);
      final folder = relative.split('/').take(2).join('/');
      await client.ensureDirectory(folder);
      await client.uploadFile(relative, file);
      uploaded++;
    } catch (error) {
      failures[label] = '$error';
    }
  }
  onProgress?.call(jobs.length, jobs.length, '');
  return NasUploadResult(
    uploaded: uploaded,
    skipped: skipped,
    failures: failures,
  );
}
