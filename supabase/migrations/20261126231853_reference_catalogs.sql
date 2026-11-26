-- Server reference catalogs. These stable IDs are independent of fictional test data.
insert into public.houses (id, slug, name)
select ('10000000-0000-4000-8000-' || lpad(entry::text, 12, '0'))::uuid, slug, name
from (values
  (1, 'adams', 'Adams'), (2, 'cabot', 'Cabot'), (3, 'currier', 'Currier'),
  (4, 'dunster', 'Dunster'), (5, 'eliot', 'Eliot'), (6, 'kirkland', 'Kirkland'),
  (7, 'leverett', 'Leverett'), (8, 'lowell', 'Lowell'), (9, 'mather', 'Mather'),
  (10, 'pforzheimer', 'Pforzheimer'), (11, 'quincy', 'Quincy'), (12, 'winthrop', 'Winthrop')
) as catalog (entry, slug, name);

insert into public.programs (id, slug, name)
select ('20000000-0000-4000-8000-' || lpad(entry::text, 12, '0'))::uuid, slug, name
from (values
  (1, 'droit', 'Droit'), (2, 'medecine', 'Médecine'), (3, 'litterature', 'Littérature'),
  (4, 'psychologie', 'Psychologie'), (5, 'sciences-ingenieur', 'Sciences de l''ingénieur'),
  (6, 'informatique', 'Informatique'), (7, 'biologie', 'Biologie'),
  (8, 'architecture', 'Architecture'), (9, 'art', 'Art'), (10, 'sport', 'Sport'),
  (11, 'economie', 'Économie'), (12, 'sciences-sociales', 'Sciences sociales'),
  (13, 'langues-etrangeres', 'Langues étrangères'), (14, 'cinema', 'Cinéma'),
  (15, 'marketing', 'Marketing')
) as catalog (entry, slug, name);

insert into public.clubs (id, slug, name, is_active, member_capacity)
select
  ('30000000-0000-4000-8000-' || lpad(entry::text, 12, '0'))::uuid,
  slug, name, slug <> 'droit', case when slug = 'bde' then 10 end
from (values
  (1, 'bde', 'BDE'), (2, 'boxe', 'Boxe'), (3, 'natation', 'Natation'),
  (4, 'litterature', 'Littérature'), (5, 'basketball', 'Basketball'),
  (6, 'photographie', 'Photographie'), (7, 'football-americain', 'Football américain'),
  (8, 'musique', 'Musique'), (9, 'cheerleading', 'Cheerleading'),
  (10, 'hockey-sur-glace', 'Hockey sur glace'), (11, 'langues', 'Langues'),
  (12, 'arts-martiaux', 'Arts martiaux'), (13, 'journalisme', 'Journalisme'),
  (14, 'patinage-artistique', 'Patinage artistique'), (15, 'echecs', 'Échecs'),
  (16, 'debats', 'Débats'), (17, 'informatique', 'Informatique'),
  (18, 'arts-plastiques', 'Arts plastiques'), (19, 'comedie-musicale', 'Comédie musicale'),
  (20, 'danse', 'Danse'), (21, 'lacrosse', 'Lacrosse'), (22, 'escrime', 'Escrime'),
  (23, 'cinema', 'Cinéma'), (24, 'theatre', 'Théâtre'), (25, 'sciences', 'Sciences'),
  (26, 'jeux-video', 'Jeux vidéo'), (27, 'radio', 'Radio'), (28, 'restauration', 'Restauration'),
  (29, 'urbex', 'Urbex'), (30, 'aventure', 'Aventure'), (31, 'automobile', 'Automobile'),
  (32, 'equitation', 'Équitation'), (33, 'droit', 'Droit')
) as catalog (entry, slug, name);
