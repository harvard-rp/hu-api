import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { createInterface } from 'node:readline';
import process from 'node:process';
import { setTimeout as delay } from 'node:timers/promises';

function session() {
  const client = spawn('docker', [
    'exec',
    '-i',
    '--user',
    'postgres',
    'supabase_db_hu-api',
    'psql',
    '-XqAt',
    '-v',
    'ON_ERROR_STOP=1',
    '-v',
    'VERBOSITY=verbose',
    '-h',
    '/var/run/postgresql',
    '-U',
    'postgres',
    '-d',
    'postgres',
  ]);
  client.stdin.on('error', () => {});
  let stdout = '';
  let stderr = '';
  client.stdout.setEncoding('utf8').on('data', (chunk) => (stdout += chunk));
  client.stderr.setEncoding('utf8').on('data', (chunk) => (stderr += chunk));
  const done = once(client, 'close').then(([code]) => ({
    code,
    stdout,
    stderr,
  }));
  return { client, done };
}

async function query(sql) {
  const { client, done } = session();
  client.stdin.end(sql);
  const result = await done;
  assert.equal(result.code, 0, 'Fixture or database probe failed.');
  return result.stdout.trim();
}

async function compete(first, second, constraint) {
  const leader = session();
  const follower = session();
  const application = `hu004-test-${randomUUID()}`;
  const lines = createInterface({ input: leader.client.stdout });
  try {
    const ready = once(lines, 'line');
    leader.client.stdin.write(
      `begin; set idle_in_transaction_session_timeout = '15s'; ${first}; select 'ready';\n`,
    );
    assert.equal(
      await Promise.race([
        ready.then(([line]) => line),
        leader.done.then(() => ''),
      ]),
      'ready',
      'The leader must hold its write uncommitted.',
    );

    follower.client.stdin.end(
      `set application_name = '${application}'; set lock_timeout = '10s'; ${second};`,
    );
    const waitQuery = `select exists (select 1 from pg_stat_activity
      where application_name = '${application}' and wait_event_type = 'Lock');`;
    const deadline = Date.now() + 5000;
    let blocked = false;
    while (!blocked && Date.now() < deadline) {
      blocked = (await query(waitQuery)) === 't';
      if (!blocked) await delay(25);
    }
    assert.ok(
      blocked,
      'The second write must wait for the uncommitted reservation.',
    );

    leader.client.stdin.end('commit;');
    const [winner, loser] = await Promise.all([leader.done, follower.done]);
    assert.equal(winner.code, 0, 'The first reservation should commit.');
    assert.notEqual(loser.code, 0, 'The competing reservation must fail.');
    assert.ok(
      loser.stderr.includes('23505') && loser.stderr.includes(constraint),
      `Expected a unique violation on ${constraint}.`,
    );
    process.stdout.write(`Verified concurrent reservation of ${constraint}.\n`);
  } finally {
    lines.close();
    leader.client.stdin.end();
    follower.client.stdin.end();
    await Promise.allSettled([leader.done, follower.done]);
  }
}

const player = randomUUID();
const characters = Array.from({ length: 12 }, () => randomUUID());
const [clubCharacter, ...bdeCharacters] = characters;
const [firstBdeCandidate, secondBdeCandidate, ...bdeMembers] = bdeCharacters;

function membership(character, slug, slot, seat = 'null') {
  return `insert into private.club_memberships
    (character_id, club_id, club_capacity_key, character_slot, club_seat)
    select '${character}', id, capacity_key, ${slot}, ${seat} from public.clubs where slug = '${slug}'`;
}

try {
  await query(`begin;
    insert into private.players (id, discord_id)
    values ('${player}', (('x' || substr(replace('${player}', '-', ''), 1, 15))::bit(60)::bigint + 1)::text);
    insert into private.characters (id, player_id, kind) values
      ${characters.map((id) => `('${id}', '${player}', 'student')`).join(', ')};
    ${membership(clubCharacter, 'boxe', 1)};
    ${bdeMembers.map((id, index) => membership(id, 'bde', 1, index + 1)).join(';\n')};
    commit;`);

  await compete(
    membership(clubCharacter, 'natation', 2),
    membership(clubCharacter, 'musique', 2),
    'club_memberships_unique_character_slot',
  );
  await compete(
    membership(firstBdeCandidate, 'bde', 1, 10),
    membership(secondBdeCandidate, 'bde', 1, 10),
    'club_memberships_unique_club_seat',
  );
  assert.equal(
    await query(`select count(*) from private.club_memberships
    where character_id = '${clubCharacter}' and status = 'active';`),
    '2',
  );
  assert.equal(
    await query(`select count(*) from private.club_memberships m
    join public.clubs c on c.id = m.club_id join private.characters p on p.id = m.character_id
    where c.slug = 'bde' and m.status = 'active' and p.player_id = '${player}';`),
    '10',
  );
} finally {
  await query(`begin;
    delete from private.club_memberships where character_id in
      (select id from private.characters where player_id = '${player}');
    delete from private.characters where player_id = '${player}';
    delete from private.players where id = '${player}';
    commit;`);
}
