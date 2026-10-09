/* Smart Bin backend client (Supabase + sign-in). Runs in demo mode (local only) until config.js is filled in. */
const SB=(()=>{
  const cfg=window.SB_CONFIG||{};
  const live=!!(cfg.url&&cfg.anonKey&&!/YOUR/.test(cfg.url+cfg.anonKey));
  const db=live?supabase.createClient(cfg.url,cfg.anonKey):null;
  const ls={get(k){try{return localStorage.getItem(k)}catch(e){return null}},set(k,v){try{localStorage.setItem(k,v)}catch(e){}}};
  const local=()=>{try{return JSON.parse(ls.get('sb_local')||'{"p":0}')}catch(e){return{p:0}}};
  const here=()=>location.href.split('#')[0];
  let user=null,nick=ls.get('sb_name')||'Eco-'+Math.floor(1000+Math.random()*9000);

  return{
    live,
    user:()=>user,
    name:()=>nick,

    async init(){
      if(!live)return;
      const {data}=await db.auth.getSession();user=data.session?data.session.user:null;
      db.auth.onAuthStateChange((_e,s)=>{user=s?s.user:null});
    },
    async signIn(email){
      const {error}=await db.auth.signInWithOtp({email,options:{emailRedirectTo:here()}});
      return error?{error:error.message}:{ok:true};
    },
    async signInGoogle(){
      const {error}=await db.auth.signInWithOAuth({provider:'google',options:{redirectTo:here()}});
      return error?{error:error.message}:{ok:true};
    },
    async signOut(){if(live)await db.auth.signOut();user=null},

    async refresh(){
      if(!live||!user)return;
      const {data}=await db.rpc('get_profile');if(data&&data[0])nick=data[0].nick;
    },
    async setName(n){
      n=(n||'').trim().slice(0,20);if(!n)return;
      if(!live){nick=n;ls.set('sb_name',n);return}
      const {error}=await db.rpc('set_nickname',{p_name:n});if(!error)nick=n;
    },

    // Uploads both proof photos, then the server awards the points.
    async submit(bin,dataUrls,aiOk){
      if(!live){const l=local();const pts=aiOk?10:5;l.p+=pts;ls.set('sb_local',JSON.stringify(l));return{awarded:pts,balance:l.p}}
      if(!user)return{error:'Please sign in.'};
      try{
        const paths=[];
        for(let i=0;i<dataUrls.length;i++){
          const blob=await (await fetch(dataUrls[i])).blob();
          const path=`${user.id}/${Date.now()}-${i}.jpg`;
          const {error}=await db.storage.from('proofs').upload(path,blob,{contentType:'image/jpeg'});
          if(error)throw error;paths.push(path);
        }
        const {data,error}=await db.rpc('submit_disposal',{p_bin:bin,p_photos:paths,p_ai_ok:!!aiOk});
        if(error)throw error;
        return{awarded:data.awarded,balance:data.balance};
      }catch(e){
        return{error:/wait|limit|sign in/i.test(e.message||'')?e.message:'Upload failed. Check your connection and try again.'};
      }
    },
    async leaderboard(){
      if(!live)return[{nickname:nick,lifetime:local().p,me:true}];
      const {data}=await db.rpc('get_leaderboard');return data||[];
    },
    async balance(){
      if(!live)return local().p;
      const {data}=await db.rpc('get_profile');return data&&data[0]?data[0].pts:0;
    },
    async redeem(){
      if(!live)return{error:'Connect the backend to redeem rewards.'};
      const {data,error}=await db.rpc('redeem_reward',{p_reward:'garden-yoghurt'});
      return error?{error:error.message}:{code:data};
    },
    async codes(){
      if(!live||!user)return[];
      const {data}=await db.rpc('get_my_redemptions');return data||[];
    }
  };
})();
