"""Durable park-only scene conversations; generated turns commit after playback."""
from __future__ import annotations
import asyncio
import hashlib
import json
import uuid
from copy import deepcopy
from pathlib import Path
from typing import Any


class ParkSessions:
    def __init__(self, directory: Path):
        self.directory = directory
        self.directory.mkdir(parents=True, exist_ok=True)
        self.sessions: dict[str, dict] = {}
        self.locks: dict[str, asyncio.Lock] = {}
        self.prepare_lock = asyncio.Lock()
        self.prepare_requests: dict[str, str] = {}

    def get(self, identity: str) -> dict:
        try:
            if str(uuid.UUID(identity)) != identity: raise ValueError()
        except ValueError:
            raise KeyError('unknown scene session')
        if identity not in self.sessions:
            path=self.directory / (identity+'.json')
            if not path.exists(): raise KeyError('unknown scene session')
            self.sessions[identity]=json.loads(path.read_text(encoding='utf-8'))
            self.sessions[identity]['active_request']=''
        return self.sessions[identity]

    def write(self, session: dict) -> None:
        identity=session['id']
        self.sessions[identity]=session
        path=self.directory / (identity+'.json')
        temp=path.with_suffix('.tmp')
        temp.write_text(json.dumps(session,ensure_ascii=False,indent=2),encoding='utf-8')
        temp.replace(path)

    def new(self, cue_id: str, history: list, decisions: dict, state: dict, fingerprint: str, parent_id: str='') -> dict:
        session={'id':str(uuid.uuid4()),'cue_id':cue_id,'revision':0,'history':deepcopy(history[-16:]),
                 'decisions':deepcopy(decisions),'state':deepcopy(state),'plan':{},'prepared':False,'fingerprint':fingerprint,
                 'pending':None,'last_commit':None,'next_cue_id':'','ended':False,'child_id':'','generation':0,'active_request':'',
                 'parent_id':parent_id,'transcript':[],'opening_logged':False,
                 'goal_status':{'satisfied':False,'evidence':''}}
        self.write(session)
        return session

    def lock(self, identity: str) -> asyncio.Lock:
        return self.locks.setdefault(identity,asyncio.Lock())

    def cancel(self, session: dict, request_id: str='') -> None:
        pending=session.get('pending')
        if request_id and request_id != session.get('active_request') and (not pending or pending['request_id'] != request_id):
            return
        session['generation']=session.get('generation',0)+1
        session['pending']=None
        session['active_request']=''
        self.write(session)

    def commit(self, session: dict, request_id: str, revision: int) -> dict:
        last=session.get('last_commit')
        if last and last['request_id']==request_id:
            return {'session_id':session['id'],'revision':last['revision'],'committed':True}
        pending=session.get('pending')
        if revision!=session['revision'] or not pending or pending['request_id']!=request_id:
            raise ValueError('stale or missing scene turn')
        result=pending['result']
        self.ensure_transcript(session)
        session['transcript'].append({'speaker_id':'player','text':pending['message'],'kind':'player','cue_id':session['cue_id'],'request_id':request_id})
        session['history'].append({'role':'user','content':pending['message']})
        for segment in result['segments']:
            semantic={'park_dialogue_act':result['intent']['dialogue_act'],'park_action':result['action'],
                      'park_evidence':result['intent']['evidence'],'park_certainty':result['intent']['certainty'],
                      'park_beat_status':result['intent'].get('beat_status',''),
                      'park_goal_status':result['intent'].get('goal_status',''),
                      'park_expects_response':segment.get('expects_response',''),
                      'park_response_to':segment.get('response_to','')}
            session['history'].append({'role':'assistant','content':segment['reply'],
                'speaker_id':segment['speaker_id'],'mood':segment['mood'],'expression':segment['expression'],
                'semantic':json.dumps(semantic,ensure_ascii=False),'tts_text':segment['tts_text']})
            session['transcript'].append({'speaker_id':segment['speaker_id'],'text':segment['reply'],'kind':'reply','cue_id':session['cue_id'],'request_id':request_id})
        for unit in result.get('outro',[]):
            session['transcript'].append({'speaker_id':unit['speaker'],'text':unit['text'],'kind':unit['kind'],'cue_id':session['cue_id'],'source':unit.get('source','')})
            if unit['speaker'] in {'arcueid','ciel'}:
                session['history'].append({'role':'assistant','speaker_id':unit['speaker'],'content':unit['text'],'source':'fixed'})
        session['history']=session['history'][-16:]
        session['state']=pending['state']
        session['goal_status']=deepcopy(pending.get('goal_status',session.get('goal_status',{'satisfied':False,'evidence':''})))
        if result['branch_id']:
            session['decisions'][result['branch_id']]={'choice':result['action'],'text':pending['message']}
        session['next_cue_id']=result['next_cue_id']
        session['ended']=bool(result['ending'])
        session['revision']+=1
        session['last_commit']={'request_id':request_id,'revision':session['revision']}
        session['pending']=None
        self.write(session)
        return {'session_id':session['id'],'revision':session['revision'],'committed':True}

    def ensure_transcript(self, session: dict) -> None:
        if 'transcript' not in session:
            session['legacy_transcript']=True
            session['transcript']=[{'speaker_id':'player' if row.get('role')=='user' else row.get('speaker_id','ciel'),
                'text':row.get('content',''),'kind':'legacy','cue_id':session['cue_id']} for row in session['history']]

    def complete_script(self, session: dict, request_id: str, revision: int, next_cue_id: str) -> dict:
        last=session.get('last_commit')
        if last and last['request_id']==request_id:
            return {'session_id':session['id'],'revision':last['revision'],'committed':True,'next_cue_id':session['next_cue_id']}
        if revision!=session['revision'] or session.get('pending') or session.get('active_request') or session.get('next_cue_id'):
            raise ValueError('stale or busy scripted scene')
        if not session.get('opening_logged'):
            raise ValueError('scripted presentation has not completed')
        session['next_cue_id']=next_cue_id
        session['ended']=not bool(next_cue_id)
        session['revision']+=1
        session['last_commit']={'request_id':request_id,'revision':session['revision']}
        self.write(session)
        return {'session_id':session['id'],'revision':session['revision'],'committed':True,'next_cue_id':next_cue_id}

    def log_opening(self, session: dict, units: list) -> None:
        self.ensure_transcript(session)
        if session.get('opening_logged'): return
        if session.get('legacy_transcript') and session['revision']:
            session['opening_logged']=True
            self.write(session)
            return # Old played openings cannot be reinserted after later dialogue.
        for unit in units:
            session['transcript'].append({'speaker_id':unit['speaker'],'text':unit['text'],'kind':unit['kind'],
                'cue_id':session['cue_id'],'source':unit.get('source','')})
        session['opening_logged']=True
        self.write(session)

    def transcript(self, identity: str) -> tuple[list,bool]:
        chain=[]; seen=set(); current=identity; partial=False
        while current and current not in seen:
            seen.add(current); session=self.get(current); self.ensure_transcript(session)
            chain.append(session); partial=partial or bool(session.get('legacy_transcript'))
            parent=session.get('parent_id','')
            if 'parent_id' not in session: # Older versions only stored the forward link.
                for path in self.directory.glob('*.json'):
                    try:
                        candidate=json.loads(path.read_text(encoding='utf-8'))
                        if candidate.get('child_id')==current:
                            parent=candidate['id']; break
                    except (OSError,ValueError,KeyError): continue
            current=parent
        rows=[]
        for session in reversed(chain):
            entries=session['transcript']
            if session.get('legacy_transcript'):
                def key(row): return (row.get('speaker_id'),row.get('text'))
                overlap=0
                for count in range(1,min(len(rows),len(entries))+1):
                    if [key(r) for r in rows[-count:]]==[key(r) for r in entries[:count]]: overlap=count
                entries=entries[overlap:]
            rows.extend(entries)
        return rows,partial


def fingerprint(cue: dict) -> str:
    return hashlib.sha256(json.dumps(cue,ensure_ascii=False,sort_keys=True).encode()).hexdigest()


def clean_state(value: Any, actors: set[str]) -> dict[str,str]:
    if not isinstance(value,dict): return {}
    state={key:str(value[key])[:160] for key in ('current_topic','open_thread','player_request','handoff_note') if isinstance(value.get(key),str)}
    focus=value.get('speaker_focus','')
    if 'speaker_focus' in value and (focus in actors or focus==''): state['speaker_focus']=focus
    return state
