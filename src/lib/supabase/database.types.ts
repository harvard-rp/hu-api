export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

export type Database = {
  private: {
    Tables: {
      boost_confirmations: {
        Row: {
          confirmation_source: string;
          confirmed_active_boosts: number;
          confirmed_at: string;
          confirmed_by: string;
          id: string;
          player_id: string;
          reason: string;
          revision: number;
        };
        ComputedFields: never;
        Insert: {
          confirmation_source?: string;
          confirmed_active_boosts: number;
          confirmed_at?: string;
          confirmed_by: string;
          id?: string;
          player_id: string;
          reason: string;
          revision?: never;
        };
        Update: {
          confirmation_source?: string;
          confirmed_active_boosts?: number;
          confirmed_at?: string;
          confirmed_by?: string;
          id?: string;
          player_id?: string;
          reason?: string;
          revision?: never;
        };
        Relationships: [
          {
            foreignKeyName: 'boost_confirmations_confirmed_by_fkey';
            columns: ['confirmed_by'];
            isOneToOne: false;
            referencedRelation: 'staff_actors';
            referencedColumns: ['player_id'];
          },
          {
            foreignKeyName: 'boost_confirmations_player_id_fkey';
            columns: ['player_id'];
            isOneToOne: false;
            referencedRelation: 'player_slot_capacity';
            referencedColumns: ['player_id'];
          },
          {
            foreignKeyName: 'boost_confirmations_player_id_fkey';
            columns: ['player_id'];
            isOneToOne: false;
            referencedRelation: 'players';
            referencedColumns: ['id'];
          },
        ];
      };
      character_reviews: {
        Row: {
          assigned_house_id: string | null;
          character_id: string;
          decision: Database['private']['Enums']['validation_status'];
          id: string;
          note: string | null;
          player_id: string;
          reviewed_at: string;
          reviewer_id: string;
        };
        ComputedFields: never;
        Insert: {
          assigned_house_id?: string | null;
          character_id: string;
          decision: Database['private']['Enums']['validation_status'];
          id?: string;
          note?: string | null;
          player_id: string;
          reviewed_at?: string;
          reviewer_id: string;
        };
        Update: {
          assigned_house_id?: string | null;
          character_id?: string;
          decision?: Database['private']['Enums']['validation_status'];
          id?: string;
          note?: string | null;
          player_id?: string;
          reviewed_at?: string;
          reviewer_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'character_reviews_character_id_player_id_fkey';
            columns: ['character_id', 'player_id'];
            isOneToOne: false;
            referencedRelation: 'characters';
            referencedColumns: ['id', 'player_id'];
          },
          {
            foreignKeyName: 'character_reviews_reviewer_id_fkey';
            columns: ['reviewer_id'];
            isOneToOne: false;
            referencedRelation: 'staff_actors';
            referencedColumns: ['player_id'];
          },
        ];
      };
      character_sheets: {
        Row: {
          age: number | null;
          anecdotes: string | null;
          backstory: string | null;
          birth_date: string | null;
          birth_place: string | null;
          character_id: string;
          content_warnings: string[] | null;
          created_at: string;
          face_claim: string | null;
          financial_situation: string | null;
          occupation: string | null;
          origins: string | null;
          personality: string | null;
          physical_description: string | null;
          residence: string | null;
          rp_links: string[] | null;
          sexual_orientation: string | null;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          age?: number | null;
          anecdotes?: string | null;
          backstory?: string | null;
          birth_date?: string | null;
          birth_place?: string | null;
          character_id: string;
          content_warnings?: string[] | null;
          created_at?: string;
          face_claim?: string | null;
          financial_situation?: string | null;
          occupation?: string | null;
          origins?: string | null;
          personality?: string | null;
          physical_description?: string | null;
          residence?: string | null;
          rp_links?: string[] | null;
          sexual_orientation?: string | null;
          updated_at?: string;
        };
        Update: {
          age?: number | null;
          anecdotes?: string | null;
          backstory?: string | null;
          birth_date?: string | null;
          birth_place?: string | null;
          character_id?: string;
          content_warnings?: string[] | null;
          created_at?: string;
          face_claim?: string | null;
          financial_situation?: string | null;
          occupation?: string | null;
          origins?: string | null;
          personality?: string | null;
          physical_description?: string | null;
          residence?: string | null;
          rp_links?: string[] | null;
          sexual_orientation?: string | null;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'character_sheets_character_id_fkey';
            columns: ['character_id'];
            isOneToOne: true;
            referencedRelation: 'characters';
            referencedColumns: ['id'];
          },
        ];
      };
      characters: {
        Row: {
          created_at: string;
          current_review_id: string | null;
          house_id: string | null;
          house_review_id: string | null;
          id: string;
          is_scholarship_holder: boolean | null;
          kind: Database['private']['Enums']['character_kind'];
          player_id: string;
          program_id: string | null;
          updated_at: string;
          use_status: Database['private']['Enums']['character_use_status'];
          validation_status: Database['private']['Enums']['validation_status'];
        };
        ComputedFields: never;
        Insert: {
          created_at?: string;
          current_review_id?: string | null;
          house_id?: string | null;
          house_review_id?: string | null;
          id?: string;
          is_scholarship_holder?: boolean | null;
          kind: Database['private']['Enums']['character_kind'];
          player_id: string;
          program_id?: string | null;
          updated_at?: string;
          use_status?: Database['private']['Enums']['character_use_status'];
          validation_status?: Database['private']['Enums']['validation_status'];
        };
        Update: {
          created_at?: string;
          current_review_id?: string | null;
          house_id?: string | null;
          house_review_id?: string | null;
          id?: string;
          is_scholarship_holder?: boolean | null;
          kind?: Database['private']['Enums']['character_kind'];
          player_id?: string;
          program_id?: string | null;
          updated_at?: string;
          use_status?: Database['private']['Enums']['character_use_status'];
          validation_status?: Database['private']['Enums']['validation_status'];
        };
        Relationships: [
          {
            foreignKeyName: 'characters_current_review_fk';
            columns: ['id', 'current_review_id', 'validation_status'];
            isOneToOne: false;
            referencedRelation: 'character_reviews';
            referencedColumns: ['character_id', 'id', 'decision'];
          },
          {
            foreignKeyName: 'characters_house_review_fk';
            columns: ['id', 'house_review_id', 'house_id'];
            isOneToOne: false;
            referencedRelation: 'character_reviews';
            referencedColumns: ['character_id', 'id', 'assigned_house_id'];
          },
          {
            foreignKeyName: 'characters_player_id_fkey';
            columns: ['player_id'];
            isOneToOne: false;
            referencedRelation: 'player_slot_capacity';
            referencedColumns: ['player_id'];
          },
          {
            foreignKeyName: 'characters_player_id_fkey';
            columns: ['player_id'];
            isOneToOne: false;
            referencedRelation: 'players';
            referencedColumns: ['id'];
          },
        ];
      };
      club_memberships: {
        Row: {
          character_id: string;
          character_slot: number | null;
          club_capacity_key: number;
          club_id: string;
          club_seat: number | null;
          id: string;
          joined_at: string;
          responsibility: string | null;
          status: Database['private']['Enums']['club_membership_status'];
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          character_id: string;
          character_slot?: number | null;
          club_capacity_key?: number;
          club_id: string;
          club_seat?: number | null;
          id?: string;
          joined_at?: string;
          responsibility?: string | null;
          status?: Database['private']['Enums']['club_membership_status'];
          updated_at?: string;
        };
        Update: {
          character_id?: string;
          character_slot?: number | null;
          club_capacity_key?: number;
          club_id?: string;
          club_seat?: number | null;
          id?: string;
          joined_at?: string;
          responsibility?: string | null;
          status?: Database['private']['Enums']['club_membership_status'];
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'club_memberships_character_id_fkey';
            columns: ['character_id'];
            isOneToOne: false;
            referencedRelation: 'characters';
            referencedColumns: ['id'];
          },
        ];
      };
      players: {
        Row: {
          auth_user_id: string | null;
          created_at: string;
          discord_id: string;
          id: string;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          auth_user_id?: string | null;
          created_at?: string;
          discord_id: string;
          id?: string;
          updated_at?: string;
        };
        Update: {
          auth_user_id?: string | null;
          created_at?: string;
          discord_id?: string;
          id?: string;
          updated_at?: string;
        };
        Relationships: [];
      };
      staff_actors: {
        Row: {
          created_at: string;
          player_id: string;
        };
        ComputedFields: never;
        Insert: {
          created_at?: string;
          player_id: string;
        };
        Update: {
          created_at?: string;
          player_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'staff_actors_player_id_fkey';
            columns: ['player_id'];
            isOneToOne: true;
            referencedRelation: 'player_slot_capacity';
            referencedColumns: ['player_id'];
          },
          {
            foreignKeyName: 'staff_actors_player_id_fkey';
            columns: ['player_id'];
            isOneToOne: true;
            referencedRelation: 'players';
            referencedColumns: ['id'];
          },
        ];
      };
      staff_capabilities: {
        Row: {
          capability: Database['private']['Enums']['staff_capability'];
          granted_at: string;
          staff_actor_id: string;
        };
        ComputedFields: never;
        Insert: {
          capability: Database['private']['Enums']['staff_capability'];
          granted_at?: string;
          staff_actor_id: string;
        };
        Update: {
          capability?: Database['private']['Enums']['staff_capability'];
          granted_at?: string;
          staff_actor_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'staff_capabilities_staff_actor_id_fkey';
            columns: ['staff_actor_id'];
            isOneToOne: false;
            referencedRelation: 'staff_actors';
            referencedColumns: ['player_id'];
          },
        ];
      };
    };
    Views: {
      player_slot_capacity: {
        Row: {
          allowed_slots: number | null;
          confirmed_active_boosts: number | null;
          player_id: string;
        };
        ComputedFields: never;
        Relationships: [];
      };
    };
    Functions: {
      [_ in never]: never;
    };
    Enums: {
      character_kind: 'student' | 'teacher' | 'staff_member' | 'citizen';
      character_use_status: 'active' | 'suspended';
      club_membership_status: 'active' | 'inactive';
      staff_capability: 'characters.review' | 'boosts.manage';
      validation_status:
        'draft' | 'submitted' | 'changes_requested' | 'approved' | 'rejected';
    };
    CompositeTypes: {
      [_ in never]: never;
    };
  };
  public: {
    Tables: {
      character_profiles: {
        Row: {
          character_id: string;
          created_at: string;
          first_name: string | null;
          last_name: string | null;
          nickname: string | null;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          character_id: string;
          created_at?: string;
          first_name?: string | null;
          last_name?: string | null;
          nickname?: string | null;
          updated_at?: string;
        };
        Update: {
          character_id?: string;
          created_at?: string;
          first_name?: string | null;
          last_name?: string | null;
          nickname?: string | null;
          updated_at?: string;
        };
        Relationships: [];
      };
      clubs: {
        Row: {
          capacity_key: number | null;
          created_at: string;
          id: string;
          is_active: boolean;
          member_capacity: number | null;
          name: string;
          slug: string;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          capacity_key?: never;
          created_at?: string;
          id?: string;
          is_active?: boolean;
          member_capacity?: number | null;
          name: string;
          slug: string;
          updated_at?: string;
        };
        Update: {
          capacity_key?: never;
          created_at?: string;
          id?: string;
          is_active?: boolean;
          member_capacity?: number | null;
          name?: string;
          slug?: string;
          updated_at?: string;
        };
        Relationships: [];
      };
      houses: {
        Row: {
          created_at: string;
          id: string;
          is_active: boolean;
          name: string;
          slug: string;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          created_at?: string;
          id?: string;
          is_active?: boolean;
          name: string;
          slug: string;
          updated_at?: string;
        };
        Update: {
          created_at?: string;
          id?: string;
          is_active?: boolean;
          name?: string;
          slug?: string;
          updated_at?: string;
        };
        Relationships: [];
      };
      programs: {
        Row: {
          created_at: string;
          id: string;
          is_active: boolean;
          name: string;
          slug: string;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          created_at?: string;
          id?: string;
          is_active?: boolean;
          name: string;
          slug: string;
          updated_at?: string;
        };
        Update: {
          created_at?: string;
          id?: string;
          is_active?: boolean;
          name?: string;
          slug?: string;
          updated_at?: string;
        };
        Relationships: [];
      };
    };
    Views: {
      [_ in never]: never;
    };
    Functions: {
      current_player_context: {
        Args: Record<PropertyKey, never>;
        Returns: Json;
      };
    };
    Enums: {
      [_ in never]: never;
    };
    CompositeTypes: {
      [_ in never]: never;
    };
  };
};

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>;

type DefaultSchema = DatabaseWithoutInternals[Extract<
  keyof Database,
  'public'
>];

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema['Tables'] & DefaultSchema['Views'])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables'] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Views'])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables'] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Views'])[TableName] extends {
      Row: infer R;
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema['Tables'] &
        DefaultSchema['Views'])
    ? (DefaultSchema['Tables'] &
        DefaultSchema['Views'])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R;
      }
      ? R
      : never
    : never;

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    keyof DefaultSchema['Tables'] | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables']
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables'][TableName] extends {
      Insert: infer I;
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema['Tables']
    ? DefaultSchema['Tables'][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I;
      }
      ? I
      : never
    : never;

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    keyof DefaultSchema['Tables'] | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables']
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables'][TableName] extends {
      Update: infer U;
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema['Tables']
    ? DefaultSchema['Tables'][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U;
      }
      ? U
      : never
    : never;

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    keyof DefaultSchema['Enums'] | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions['schema']]['Enums']
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions['schema']]['Enums'][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema['Enums']
    ? DefaultSchema['Enums'][DefaultSchemaEnumNameOrOptions]
    : never;

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema['CompositeTypes']
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions['schema']]['CompositeTypes']
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions['schema']]['CompositeTypes'][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema['CompositeTypes']
    ? DefaultSchema['CompositeTypes'][PublicCompositeTypeNameOrOptions]
    : never;

export const Constants = {
  private: {
    Enums: {
      character_kind: ['student', 'teacher', 'staff_member', 'citizen'],
      character_use_status: ['active', 'suspended'],
      club_membership_status: ['active', 'inactive'],
      staff_capability: ['characters.review', 'boosts.manage'],
      validation_status: [
        'draft',
        'submitted',
        'changes_requested',
        'approved',
        'rejected',
      ],
    },
  },
  public: {
    Enums: {},
  },
} as const;
