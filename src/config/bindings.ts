export type SupabaseBindings = {
  SUPABASE_URL?: string;
  SUPABASE_PUBLISHABLE_KEY?: string;
};

export type Bindings = SupabaseBindings & {
  CORS_ALLOWED_ORIGINS?: string;
};
