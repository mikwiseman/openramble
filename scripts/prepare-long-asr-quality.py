#!/usr/bin/env python3
"""Frozen Eleven v4 continuous fictional narrations and word-boundary excerpts.

One library voice per parent, unique adjacent paragraphs, no loops or inserted
silence. The API requires paragraph requests; their seams remain explicit.
All durations share their parent's identity. Intended scripts are not human gold.
"""
import argparse
import base64
import fcntl
import importlib.util
import json
import math
import os
import re
import wave
from pathlib import Path

spec = importlib.util.spec_from_file_location('synthetic', Path(__file__).with_name('prepare-synthetic-asr-quality.py'))
synthetic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(synthetic)
prepare = synthetic.prepare
PARENTS = (('ru', synthetic.VOICE_IDS[0]), ('en', synthetic.VOICE_IDS[2]), ('mixed', synthetic.VOICE_IDS[1]))
SAMPLE_RATE = 16000
MAX_CHARACTERS = 1800


def durable_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.part')
    with temporary.open('w') as stream:
        json.dump(value, stream, ensure_ascii=False, sort_keys=True, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def split_chunks(text):
    paragraphs = [p.strip() for p in text.strip().split('\n\n') if p.strip()]
    if len(set(paragraphs)) != len(paragraphs):
        raise ValueError('a repeated paragraph is not a genuine long narration')
    chunks = []
    current = ''
    for paragraph in paragraphs:
        if len(paragraph) > MAX_CHARACTERS:
            raise ValueError('author shorter paragraphs; never split inside a word')
        proposed = current + '\n\n' + paragraph if current else paragraph
        if len(proposed) > MAX_CHARACTERS:
            chunks.append(current)
            current = paragraph
        else:
            current = proposed
    if current:
        chunks.append(current)
    if not chunks or ''.join(''.join(chunks).split()) != ''.join(text.split()):
        raise ValueError('chunking must preserve every authored word')
    return chunks


def aligned_words(text, alignment, duration):
    characters = alignment['characters']
    starts = alignment['character_start_times_seconds']
    ends = alignment['character_end_times_seconds']
    if ''.join(characters) != text or len(starts) != len(characters) or len(ends) != len(characters):
        raise ValueError('provider alignment must cover the exact frozen intended script')
    if any(not math.isfinite(a) or not math.isfinite(b) or a < 0 or b < a or b > duration + .05
           for a, b in zip(starts, ends)):
        raise ValueError('invalid character timing or truncated audio')
    words = []
    for match in re.finditer(r'\S+', text):
        indices = [i for i in range(match.start(), match.end()) if text[i].isalnum()]
        if not indices:
            continue
        words.append({'text': match.group(), 'character_end': match.end(),
                      'start': min(starts[i] for i in indices), 'end': max(ends[i] for i in indices)})
    if not words or any(a['start'] > b['start'] for a, b in zip(words, words[1:])):
        raise ValueError('word order differs from frozen narration')
    return words


def word_cut(words, duration, requested):
    if duration < requested:
        raise ValueError('parent is too short; padding or repeating is forbidden')
    boundaries = []
    for index, word in enumerate(words):
        following = words[index + 1]['start'] if index + 1 < len(words) else duration
        if following >= word['end']:
            boundaries.append(((word['end'] + following) / 2, index))
    if not boundaries:
        raise ValueError('no verified inter-word boundary')
    cut, index = min(boundaries, key=lambda pair: abs(pair[0] - requested))
    if abs(cut - requested) > 3:
        raise ValueError('no word boundary within three seconds of requested duration')
    return cut, words[index]['character_end']


def plan(args):
    short = json.loads((args.root / 'manifests/synthetic-plan.json').read_text())
    known_voices = {v['voice_id']: v for v in short['voices']}
    parents, jobs = [], []
    for language, voice_id in PARENTS:
        voice = known_voices[voice_id]
        if voice['rate'] != 1:
            raise ValueError('frozen ordinary library voice required')
        source = Path(__file__).resolve().parents[1] / f'research/asr-quality-2026-09/long-{language}.txt'
        text = source.read_text().strip()
        if len(text.split()) < 3000:
            raise ValueError('long narration needs at least 3000 distinct-content words')
        parent_id = f'eleven-long-{language}'
        chunks = split_chunks(text)
        parents.append({'id': parent_id, 'language': language, 'voice': voice, 'split': 'holdout',
                        'source_sha256': prepare.sha256(source), 'intended_words': len(text.split()),
                        'jobs': [f'{parent_id}-{i:03d}' for i in range(len(chunks))]})
        for i, chunk in enumerate(chunks):
            payload = {'inputs': [{'text': chunk, 'voice_id': voice_id}], 'model_id': synthetic.MODEL,
                       'seed': 20260930, 'settings': {'stability': .5, 'similarity': .75},
                       'apply_text_normalization': 'on'}
            if language != 'mixed':
                payload['language_code'] = language
            jobs.append({'id': f'{parent_id}-{i:03d}', 'parent_id': parent_id, 'reference': chunk,
                         'payload': payload, 'characters': len(chunk),
                         'maximum_cost_usd': len(chunk) * synthetic.RATE_PER_1000 / 1000})
    estimated = sum(job['maximum_cost_usd'] for job in jobs)
    existing = json.loads((args.root / 'synthetic/ledger.json').read_text())
    reserved = sum(item['maximum_cost_usd'] for item in existing.values())
    if estimated + reserved > synthetic.BUDGET:
        raise ValueError('frozen plan exceeds shared authorized synthesis budget')
    document = {'model_id': synthetic.MODEL, 'parents': parents, 'jobs': jobs, 'ai_generated': True,
                'estimated_additional_cost_usd': estimated, 'maximum_total_budget_usd': synthetic.BUDGET,
                'undiscounted_rate_per_1000': synthetic.RATE_PER_1000,
                'generation_endpoint': '/v1/text-to-dialogue/with-timestamps?output_format=pcm_16000',
                'api_reference': 'https://elevenlabs.io/docs/api-reference/text-to-dialogue/convert-with-timestamps',
                'continuity': 'adjacent unique paragraphs in one library voice; native request pauses retained; no loops or added silence; all API seams annotated',
                'policy': 'one attempt per frozen paragraph/voice; uncertain and failed attempts reserve budget; no automatic paid retries',
                'reference_scope': 'fictional intended script with provider alignment, not independently verified spoken gold'}
    destination = args.root / 'manifests/synthetic-long-plan.json'
    if destination.exists() and json.loads(destination.read_text()) != document:
        raise ValueError('long plan already differs')
    durable_json(destination, document)
    print(f'sealed 3 parents, {len(jobs)} requests; additional cost <=${estimated:.2f}', flush=True)


def generate(args):
    key = args.key_file.read_text().strip()
    document = json.loads((args.root / 'manifests/synthetic-long-plan.json').read_text())
    folder = args.root / 'synthetic/long-generations'
    folder.mkdir(parents=True, exist_ok=True)
    with (args.root / 'synthetic/ledger.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        ledger_path = args.root / 'synthetic/ledger.json'
        ledger = json.loads(ledger_path.read_text())
        for job in document['jobs']:
            payload_hash = prepare.text_hash(json.dumps(job['payload'], sort_keys=True))
            if job['id'] in ledger:
                entry = ledger[job['id']]
                if entry['payload_sha256'] != payload_hash or entry['status'] != 'ok':
                    raise ValueError('previous attempt needs review; never automatically regenerate it')
                if prepare.sha256(Path(entry['audio_path'])) != entry['audio_sha256']:
                    raise ValueError('generated source hash changed')
                continue
            subscription, _ = synthetic.api(key, '/v1/user/subscription')
            available = subscription['character_limit'] - subscription['character_count']
            if available < job['characters']:
                durable_json(args.root / 'synthetic/quota-check.json', {
                    'status': 'insufficient_credits', 'remaining': available,
                    'next_job_characters': job['characters'], 'reset_unix': subscription['next_character_count_reset_unix'],
                    'billing_changes': False})
                print(f'Eleven v4 quota: {available} remaining; long checkpoint preserved', flush=True)
                return
            reserved = sum(item['maximum_cost_usd'] for item in ledger.values())
            if reserved + job['maximum_cost_usd'] > synthetic.BUDGET:
                raise ValueError('shared authorized synthesis budget exhausted')
            entry = {'status': 'attempted', 'maximum_cost_usd': job['maximum_cost_usd'],
                     'characters': job['characters'], 'payload_sha256': payload_hash}
            ledger[job['id']] = entry
            durable_json(ledger_path, ledger)  # Must reach disk BEFORE the paid request.
            try:
                response, headers = synthetic.api(key, document['generation_endpoint'], job['payload'])
                response_path = folder / (job['id'] + '.json')
                durable_json(response_path, response)
                pcm = base64.b64decode(response['audio_base64'], validate=True)
                if not pcm or len(pcm) % 2:
                    raise ValueError('invalid PCM response')
                destination = folder / (job['id'] + '.wav')
                temporary = destination.with_suffix('.wav.part')
                with wave.open(str(temporary), 'wb') as output:
                    output.setparams((1, 2, SAMPLE_RATE, 0, 'NONE', 'not compressed'))
                    output.writeframes(pcm)
                temporary.replace(destination)
                entry.update({'audio_path': str(destination), 'audio_sha256': prepare.sha256(destination),
                              'response_sha256': prepare.sha256(response_path), 'duration_seconds': len(pcm) / 32000,
                              'request_id': headers.get('request-id') or headers.get('Request-Id'),
                              'charged_characters': headers.get('character-cost') or headers.get('Character-Cost')})
                aligned_words(job['reference'], response['alignment'], entry['duration_seconds'])
                entry['status'] = 'ok'
            except Exception as error:
                # Preserve charged/uncertain attempts. Never print key, body or provider error text.
                entry.update({'status': 'needs_review', 'error_type': type(error).__name__})
                if hasattr(error, 'code'):
                    entry['http_status'] = error.code
            durable_json(ledger_path, ledger)
            print(f"Eleven long: {job['id']} {entry['status']}; reserved <=${reserved + job['maximum_cost_usd']:.2f}", flush=True)
            if entry['status'] != 'ok':
                return


def write_pcm(path, pcm):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        with wave.open(str(path), 'rb') as existing:
            if existing.getparams()[:3] != (1, 2, SAMPLE_RATE) or existing.readframes(existing.getnframes()) != pcm:
                raise ValueError('sealed parent/excerpt differs')
        return
    temporary = path.with_suffix('.wav.part')
    with wave.open(str(temporary), 'wb') as output:
        output.setparams((1, 2, SAMPLE_RATE, 0, 'NONE', 'not compressed'))
        output.writeframes(pcm)
    temporary.replace(path)


def freeze(args):
    document = json.loads((args.root / 'manifests/synthetic-long-plan.json').read_text())
    ledger = json.loads((args.root / 'synthetic/ledger.json').read_text())
    jobs = {job['id']: job for job in document['jobs']}
    fixtures, parents = [], []
    for parent in document['parents']:
        pcm, text, words, seams = bytearray(), '', [], []
        for job_id in parent['jobs']:
            job, entry = jobs[job_id], ledger.get(job_id, {})
            if entry.get('status') != 'ok' or prepare.sha256(Path(entry['audio_path'])) != entry['audio_sha256']:
                raise ValueError('full parent is not generated and verified')
            response_path = args.root / 'synthetic/long-generations' / (job_id + '.json')
            if prepare.sha256(response_path) != entry['response_sha256']:
                raise ValueError('sealed alignment changed')
            response = json.loads(response_path.read_text())
            with wave.open(entry['audio_path'], 'rb') as source:
                if source.getparams()[:3] != (1, 2, SAMPLE_RATE):
                    raise ValueError('source PCM format differs')
                chunk = source.readframes(source.getnframes())
            offset = len(pcm) / 32000
            if pcm:
                seams.append(offset)
                text += ' '
            characters = len(text)
            for word in aligned_words(job['reference'], response['alignment'], len(chunk) / 32000):
                words.append(word | {'start': word['start'] + offset, 'end': word['end'] + offset,
                                     'character_end': word['character_end'] + characters})
            text += job['reference']
            pcm.extend(chunk)
        duration = len(pcm) / 32000
        if duration < 900:
            raise ValueError('genuine parent must exceed fifteen minutes; never pad or loop')
        folder = args.root / 'synthetic/long-parents'
        parent_path = folder / (parent['id'] + '.wav')
        write_pcm(parent_path, pcm)
        durable_json(folder / (parent['id'] + '.alignment.json'), {'text': text, 'words': words, 'api_seams_seconds': seams})
        parents.append(parent | {'audio_sha256': prepare.sha256(parent_path), 'duration_seconds': duration,
                                 'api_seams_seconds': seams, 'reference_scope': document['reference_scope']})
        for minutes in (4, 5, 8, 15):
            cut, character_end = word_cut(words, duration, minutes * 60)
            frames = int(cut * SAMPLE_RATE)
            fixture_id = f"{parent['id']}-{minutes}min"
            path = args.root / 'synthetic/long-excerpts' / (fixture_id + '.wav')
            write_pcm(path, pcm[:frames * 2])
            fixtures.append({'id': fixture_id, 'dataset': 'eleven_v4_long', 'split': 'holdout',
                             'language': parent['language'], 'group_id': parent['id'], 'path': str(path),
                             'canonical_path': str(args.root / 'canonical' / (fixture_id + '.wav')),
                             'reference': text[:character_end], 'reference_scope': document['reference_scope'],
                             'requested_seconds': minutes * 60, 'actual_seconds': frames / SAMPLE_RATE,
                             'parent_audio_sha256': prepare.sha256(parent_path), 'ai_generated': True,
                             'api_seams_seconds': [s for s in seams if s < cut]})
    prepare.freeze(args.root, 'synthetic-long', fixtures, [{
        'provider': 'ElevenLabs', 'model_id': synthetic.MODEL,
        'plan_sha256': prepare.sha256(args.root / 'manifests/synthetic-long-plan.json'),
        'parents': parents, 'continuity': document['continuity'],
        'grouping': 'three parent narrations, never twelve independent sources'}], args.asr_bin)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('plan', 'generate', 'freeze'))
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--key-file', type=Path)
    parser.add_argument('--asr-bin', type=Path)
    args = parser.parse_args()
    if args.root.resolve().is_relative_to(Path(__file__).resolve().parents[1]):
        parser.error('data root must be outside Git')
    if args.phase == 'generate' and args.key_file is None:
        parser.error('--key-file required')
    if args.phase == 'freeze' and args.asr_bin is None:
        parser.error('--asr-bin required')
    {'plan': plan, 'generate': generate, 'freeze': freeze}[args.phase](args)


if __name__ == '__main__':
    main()
