import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { registerHooks } from 'node:module';
import { rootCertificates } from 'node:tls';
import { spawnSync } from 'node:child_process';
const results=[];
function check(name,fn){try{fn();results.push({name,ok:true})}catch(error){results.push({name,ok:false,error:error.message})}}
check('platform',()=>assert.equal(process.platform,'ios'));
check('module-hooks',()=>assert.equal(typeof registerHooks,'function'));
check('sqlite',()=>{const db=new DatabaseSync(':memory:');assert.equal(db.prepare('select 42 value').get().value,42);db.close()});
check('wasm-memory',()=>assert.ok(new WebAssembly.Memory({initial:1}).buffer.byteLength));
check('tls-roots',()=>assert.ok(rootCertificates.length>0));
check('shell',()=>{const result=spawnSync('/var/jb/bin/sh',['-c','exit 0']);assert.equal(result.status,0)});
check('runtime-flags',()=>{for(const flag of ['--predictable','--single-threaded','--disable-wasm-trap-handler'])assert.ok(process.execArgv.includes(flag),flag)});
console.log(JSON.stringify({node:process.version,platform:process.platform,results},null,2));
if(results.some(result=>!result.ok))process.exitCode=1;
