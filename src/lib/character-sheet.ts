import { z } from '@hono/zod-openapi';

export const characterKind = z.enum([
  'student',
  'teacher',
  'staff_member',
  'citizen',
]);

export const rpString = (limit: number) =>
  z
    .string()
    .refine(
      (value) =>
        value.isWellFormed() &&
        !value.includes('\0') &&
        /\S/u.test(value) &&
        [...value].length <= limit,
    )
    .openapi({ minLength: 1, maxLength: limit });
const rpText = (limit: number) => rpString(limit).nullable().optional();
const rpList = (limit: number) =>
  z.array(rpString(limit)).max(12).nullable().optional();

const editableFields = {
  firstName: rpText(80),
  lastName: rpText(80),
  nickname: rpText(80),
  age: z.number().int().min(0).max(32767).nullable().optional(),
  sexualOrientation: rpText(120),
  birthDate: z.iso.date().nullable().optional(),
  birthPlace: rpText(200),
  origins: rpText(200),
  residence: rpText(200),
  financialSituation: rpText(200),
  occupation: rpText(200),
  personality: rpText(4000),
  physicalDescription: rpText(4000),
  faceClaim: rpText(300),
  backstory: rpText(12000),
  anecdotes: rpText(4000),
  contentWarnings: rpList(120),
  rpLinks: rpList(300),
  programId: z.uuid().nullable().optional(),
  isScholarshipHolder: z.boolean().nullable().optional(),
};

export const createDraft = z.strictObject({
  kind: characterKind,
  ...editableFields,
});
export const submitDraft = z.strictObject({ expectedRevision: z.uuid() });
export const editDraft = submitDraft
  .extend(editableFields)
  .refine((fields) =>
    Object.keys(fields).some((key) => key !== 'expectedRevision'),
  );

const nullableText = z.string().nullable();
const summary = z.strictObject({
  id: z.uuid(),
  kind: characterKind,
  validationStatus: z.enum([
    'draft',
    'submitted',
    'changes_requested',
    'approved',
    'rejected',
  ]),
  useStatus: z.enum(['active', 'suspended']),
  revision: z.uuid(),
  createdAt: z.iso.datetime({ offset: true }),
  updatedAt: z.iso.datetime({ offset: true }),
  firstName: nullableText,
  lastName: nullableText,
  nickname: nullableText,
});

export const characterList = z.array(summary);
export const characterDetail = summary.extend({
  houseId: z.uuid().nullable(),
  programId: z.uuid().nullable(),
  isScholarshipHolder: z.boolean().nullable(),
  age: z.number().int().min(0).max(32767).nullable(),
  sexualOrientation: nullableText,
  birthDate: nullableText,
  birthPlace: nullableText,
  origins: nullableText,
  residence: nullableText,
  financialSituation: nullableText,
  occupation: nullableText,
  personality: nullableText,
  physicalDescription: nullableText,
  faceClaim: nullableText,
  backstory: nullableText,
  anecdotes: nullableText,
  contentWarnings: z.array(nullableText).nullable(),
  rpLinks: z.array(nullableText).nullable(),
});

export const characterCapacity = z.strictObject({
  total: z.number().int().min(5),
  used: z.number().int().nonnegative(),
  available: z.number().int().nonnegative(),
});

const catalogEntry = z.strictObject({
  id: z.uuid(),
  slug: z.string(),
  name: z.string(),
});
export const characterCatalog = z.array(catalogEntry);
export const clubCatalog = z.array(
  catalogEntry.extend({
    memberCapacity: z.number().int().positive().nullable(),
  }),
);
