#!/usr/bin/env python3
"""Read-only eink own-note contract probe; never creates/deletes notes.

Uses an existing independent test login, renewing on the same deviceId only.
Prints counts/schema/ownership booleans, not credentials or note contents.
"""
import argparse
import hashlib
import json
import random
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env-file', required=True)
    parser.add_argument('--book-id', required=True)
    args = parser.parse_args()
    env = {}
    for line in Path(args.env_file).read_text().splitlines():
        if '=' in line and not line.startswith('#'):
            key, value = line.split('=', 1)
            env[key] = value.strip().strip('\"\'')
    vid = env['WEINK_EINK_VID']
    token = env['WEINK_EINK_ACCESS_TOKEN']

    def request(path, params=None, payload=None):
        headers = {'vid': vid, 'accessToken': token, 'appver': '2.1.2.10245900',
                   'basever': '2.1.2.10245900', 'baseapi': '30', 'osver': '11',
                   'channelId': '900', 'User-Agent': 'WeRead/2.1.2 WRBrand/Onyx wr_eink'}
        url = 'https://i.weread.qq.com' + path
        if params:
            url += '?' + urlencode(params)
        body = None
        if payload is not None:
            headers['Content-Type'] = 'application/json; charset=UTF-8'
            body = json.dumps(payload).encode()
        req = Request(url, data=body, headers=headers)
        try:
            with urlopen(req, timeout=30) as response:
                return json.load(response)
        except HTTPError as error:
            raise RuntimeError(f'{path}: HTTP {error.code}') from None

    stamp = int(time.time() * 1000)
    nonce = random.randint(0, 999)
    device = env['WEINK_EINK_DEVICE_ID']
    login = request('/login', payload={
        'deviceId': device, 'refreshToken': env['WEINK_EINK_REFRESH_TOKEN'],
        'timestamp': stamp, 'random': nonce, 'deviceType': 3,
        'signature': hashlib.sha256(f'{stamp}{device}{nonce}'.encode()).hexdigest(),
    })
    token = login.get('accessToken') or token
    marks = request('/book/bookmarklist', {'bookId': args.book_id})
    print('bookmarks', 'keys', sorted(marks), 'updated', len(marks.get('updated', [])))
    if marks.get('updated'):
        print('bookmark schema', sorted(marks['updated'][0]))
    for list_type in (11,):
        # NoteService.loadUserBookReviewList: USER_NOTE=11, mine=1, listMode=0.
        params = {'bookId': args.book_id, 'listType': list_type,
                  'mine': 1, 'listMode': 0, 'synckey': 0}
        for page in range(3):
            data = request('/review/list', params)
            rows = data.get('reviews') or []
            print('own reviews', list_type, 'page', page, 'keys', sorted(data), 'rows', len(rows),
                  'synckey', data.get('synckey'), 'hasMore', data.get('hasMore'),
                  'last', data.get('last'), 'totalCount', data.get('totalCount'))
            for wrapper in rows[:2]:
                item = wrapper
                while isinstance(item.get('review'), dict):
                    item = item['review']
                author = item.get('author') or {}
                print('review schema', sorted(item), 'wrapper', sorted(wrapper),
                      'type', item.get('type'), 'own', str(author.get('userVid')) == vid,
                      'author schema', sorted(author), 'same_book', str(item.get('bookId')) == args.book_id)
            if not data.get('hasMore'):
                break
            if not data.get('synckey') or data['synckey'] == params['synckey']:
                raise RuntimeError('Own-note cursor did not advance')
            params['synckey'] = data['synckey']
        else:
            print('More pages remain; read-only schema probe stops after three pages.')


if __name__ == '__main__':
    main()
