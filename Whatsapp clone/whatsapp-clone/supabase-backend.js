/* PMPR Supabase backend adapter */
(function () {
  const config = window.PMPR_SUPABASE_CONFIG || {};
  const ready = Boolean(window.supabase && config.url && config.anonKey && !config.url.includes('YOUR_PROJECT_REF') && !config.anonKey.includes('YOUR_SUPABASE'));
  const client = ready ? window.supabase.createClient(config.url, config.anonKey, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } }) : null;

  window.PMPRSupabase = {
    enabled: ready,
    client,
    async signIn(email, password) {
      if (!client) throw new Error('Supabase is not configured. Add your project URL and anon key in supabase-config.js.');
      return client.auth.signInWithPassword({ email, password });
    },
    async signInWithGoogle() {
      if (!client) throw new Error('Supabase is not configured.');
      return client.auth.signInWithOAuth({
        provider: 'google',
        options: { redirectTo: `${window.location.origin}${window.location.pathname}` }
      });
    },
    async signUp({ email, password, name, phone, avatar }) {
      if (!client) throw new Error('Supabase is not configured.');
      return client.auth.signUp({ email, password, options: { data: { name, phone, avatar_url: avatar } } });
    },
    async resetPassword(email) {
      if (!client) throw new Error('Supabase is not configured.');
      return client.auth.resetPasswordForEmail(email, { redirectTo: `${window.location.origin}${window.location.pathname}` });
    },
    async getSession() { return client ? client.auth.getSession() : { data: { session: null }, error: null }; },
    async signOut() { return client ? client.auth.signOut() : { error: null }; },
    async saveProfile(user, values) {
      if (!client || !user) return { data: null, error: null };
      return client.from('profiles').upsert({ id: user.id, email: user.email, ...values, updated_at: new Date().toISOString() });
    },
    subscribeToMessages(conversationId, callback) {
      if (!client) return null;
      return client.channel(`conversation:${conversationId}`).on('postgres_changes', { event: '*', schema: 'public', table: 'messages', filter: `conversation_id=eq.${conversationId}` }, callback).subscribe();
    },
    async uploadMedia(userId, file) {
      if (!client) throw new Error('Supabase is not configured.');
      const path = `${userId}/${crypto.randomUUID()}-${file.name.replace(/[^a-zA-Z0-9._-]/g, '_')}`;
      const result = await client.storage.from('chat-media').upload(path, file, { cacheControl: '3600', upsert: false, contentType: file.type });
      if (result.error) throw result.error;
      return result.data.path;
    }
  };
})();
