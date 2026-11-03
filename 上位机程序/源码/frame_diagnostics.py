"""Bounded, asynchronous evidence capture; never changes frame acceptance."""
import json
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from queue import SimpleQueue
from threading import BoundedSemaphore


class FrameDiagnostics:
    def __init__(self, root='F:/codex/double_eye_viewer/diagnostics_v8', limit=3):
        self.root = Path(root)
        self.limit = limit
        self.pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix='frame-evidence')
        self.slots = BoundedSemaphore(6)
        self.results = SimpleQueue()
        self.reset(0)

    def reset(self, epoch):
        self.epoch = epoch
        self.folder = self.root / (datetime.now().strftime('%Y%m%d_%H%M%S_%f') + f'_session{epoch}')
        self.counts = Counter(size_mismatch=0, marker_failure=0)
        self.details = Counter()
        self.attempts = Counter()
        self.saved = self.pending = self.skipped = 0
        self.error = ''

    def record(self, reason, image, metadata):
        self.counts[reason] += 1
        detail = metadata.get('marker', {}).get('reason')
        if reason == 'marker_failure' and detail:
            self.details[detail] += 1
        if self.attempts[reason] >= self.limit:
            return
        if not self.slots.acquire(blocking=False):
            self.skipped += 1
            return
        self.attempts[reason] += 1
        self.pending += 1
        # Own a detached image and immutable metadata across the worker boundary.
        entry = dict(metadata, reason=reason, reason_count=self.counts[reason],
                     timestamp=datetime.now().astimezone().isoformat(), epoch=self.epoch)
        stem = self.folder / f'{reason}_{self.attempts[reason]:02d}'
        self.pool.submit(self._write, image.copy(), entry, stem, self.folder)

    def _write(self, image, entry, stem, session_folder):
        error = ''
        try:
            stem.parent.mkdir(parents=True, exist_ok=True)
            # A failed video conversion has no image; retain its status as JSON.
            if not image.isNull() and not image.save(str(stem.with_suffix('.png'))):
                raise OSError('PNG 保存失败')
            roi = entry.get('marker', {}).get('roi')
            if roi and not image.copy(*roi).save(str(stem) + '_marker.png'):
                raise OSError('标记区域保存失败')
            stem.with_suffix('.json').write_text(json.dumps(entry, ensure_ascii=False, indent=2), encoding='utf-8')
        except Exception as exc:
            error = str(exc)
        finally:
            self.results.put((session_folder, error))
            self.slots.release()

    def poll(self):
        while not self.results.empty():
            folder, error = self.results.get()
            # A completed old-session save must not affect current counters.
            if folder != self.folder:
                continue
            self.pending -= 1
            if error:
                self.error = error
            else:
                self.saved += 1

    def close(self):
        self.pool.shutdown(wait=True)
        self.poll()
