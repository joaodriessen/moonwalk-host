#!/usr/bin/env python3
"""Compile exact production keyboard/reset bodies against inert recording boundaries."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
FUNCTIONS=[
 'key_press_id_t make_kpid(', 'uint16_t vk_from_kpid(', 'uint8_t flags_from_kpid(',
 'short map_keycode(', 'inline void update_shortcutFlags(', 'bool is_modifier(',
 'void send_key_and_modifiers(', 'void repeat_key(',
 'void passthrough(std::shared_ptr<input_t> &input, PNV_KEYBOARD_PACKET packet)',
 'void reset(std::shared_ptr<input_t> &input)']

def body(source, signature):
 start=source.index(signature);opening=source.index('{',start);depth=0
 for position in range(opening,len(source)):
  if source[position]=='{':depth+=1
  elif source[position]=='}':
   depth-=1
   if depth==0:return source[start:position+1],source[:start].count('\n')+1
 raise ValueError('unterminated selected function '+signature)

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',required=True,type=Path);p.add_argument('--cxx',default='c++');a=p.parse_args()
 out=a.output.resolve();out.mkdir(mode=0o700,parents=False,exist_ok=False)
 source=(ROOT/'src/input.cpp').read_text();parts=[];hashes={}
 constants=re.findall(r'^  constexpr auto VKEY_.*;',source,re.M);assert len(constants)==9
 parts.extend(constants)
 for signature in FUNCTIONS:
  selected,line=body(source,signature);hashes[signature]=hashlib.sha256(selected.encode()).hexdigest()
  parts.append('#line '+str(line)+' "src/input.cpp"\n'+selected)
 code=(HERE/'probe.cpp.in').read_text().replace('@PRODUCTION@','\n'.join(parts))
 (out/'probe.cpp').write_text(code)
 command=[a.cxx,'-std=c++17','-I'+str(ROOT),str(out/'probe.cpp'),'-o',str(out/'probe')]
 built=subprocess.run(command,capture_output=True,text=True);(out/'build.log').write_text(built.stdout+built.stderr)
 if built.returncode:raise SystemExit(built.returncode)
 run=subprocess.run([str(out/'probe')],capture_output=True,text=True);(out/'run.log').write_text(run.stdout+run.stderr)
 proof=dict(source_sha256=hashlib.sha256(source.encode()).hexdigest(),function_sha256=hashes,command=command,exit_code=run.returncode,
            runtime_scope='inert emit/queue boundaries; exact production packet/sender/repeat/reset bodies; no OS input or platform init')
 (out/'proof.json').write_text(json.dumps(proof,indent=2)+'\n');print(run.stdout,end='');print(run.stderr,end='')
 return run.returncode

if __name__=='__main__':raise SystemExit(main())
